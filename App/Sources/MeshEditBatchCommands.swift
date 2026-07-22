import CyberKit
import Foundation
import os
import simd

// Auto Relax and the EditMesh batch commands (task 4.5; spec:
// retopology-tools / "Auto Relax", "EditMesh batch commands").
//
// AUTO RELAX is not a command of its own: it is an optional MODE that runs
// the engine's relax over the neighborhood an editing operation just
// touched, INSIDE that operation's own `MeshEditTransaction`. That is the
// whole point — the journal holds ONE command whose engine-side effect
// already includes the redistribution, so the user gets one undo step per
// action rather than two. It passes the document's pin set on every call,
// so pinned vertices stay exactly where they are (spec: "honoring pins").
//
// The BATCH COMMANDS are immediate whole-mesh operations. Three of them
// (snap-all, relax-all) only move positions and leave every element id
// intact; two of them (subdivide, triangulate) change the id space, which
// orphans the document's `MeshAnnotations`. Those journal as ONE
// `DocumentCommand.compound` pairing the `meshEdit` with the
// `annotationEdit` its id churn demands — see `AnnotationIDPolicy` in
// CyberKit for the clear-never-remap convention and why.

/// One EditMesh batch command (spec: "snap-all to Target, relax-all,
/// subdivide, triangulate, clear loop tags, clear pins, and
/// subdivide+reproject"). Raw values are the accessibility-identifier
/// vocabulary the batch panel and its UI test share.
enum BatchCommand: String, CaseIterable, Identifiable, Equatable, Sendable {
    case snapAllToTarget
    case relaxAll
    case subdivide
    case subdivideAndReproject
    case triangulate
    case clearLoopTags
    case clearPins

    var id: String { rawValue }

    var title: String {
        switch self {
        case .snapAllToTarget: "Snap All to Target"
        case .relaxAll: "Relax All"
        case .subdivide: "Subdivide"
        case .subdivideAndReproject: "Subdivide + Reproject"
        case .triangulate: "Triangulate"
        case .clearLoopTags: "Clear Loop Tags"
        case .clearPins: "Clear Pins"
        }
    }

    var symbol: String {
        switch self {
        case .snapAllToTarget: "arrow.down.to.line"
        case .relaxAll: "wind"
        case .subdivide: "square.grid.2x2"
        case .subdivideAndReproject: "square.grid.3x3.square"
        case .triangulate: "triangle"
        case .clearLoopTags: "tag.slash"
        case .clearPins: "pin.slash"
        }
    }

    /// One-line description shown under the title in the panel.
    var notes: String {
        switch self {
        case .snapAllToTarget:
            "Projects every unpinned vertex onto the Target surface."
        case .relaxAll:
            "One smoothing sweep over the whole cage. Pins hold."
        case .subdivide:
            "One level of linear subdivision. Clears pins and tags — "
                + "subdividing rebuilds every element id."
        case .subdivideAndReproject:
            "Subdivides once and projects every vertex onto the Target. "
                + "Clears pins and tags for the same reason."
        case .triangulate:
            "Splits every quad and n-gon into triangles. Pins survive; "
                + "loop tags and hidden faces are cleared."
        case .clearLoopTags:
            "Removes every loop tag in one undoable step."
        case .clearPins:
            "Removes every pin in one undoable step."
        }
    }

    /// Commands that cannot run without an active Target to project onto.
    var requiresTarget: Bool {
        switch self {
        case .snapAllToTarget, .subdivideAndReproject: true
        default: false
        }
    }

    /// What the command does to the stable element ids the document's
    /// annotations are keyed on. Drives the compound journal entry.
    var annotationPolicy: AnnotationIDPolicy {
        switch self {
        case .subdivide, .subdivideAndReproject: .rebuilt
        case .triangulate: .pinsOnly
        default: .preserved
        }
    }
}

extension MeshEditController {
    private static let batchLog = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "CyberTopology", category: "batch-commands"
    )

    // MARK: - Auto Relax

    /// Extra brush radius around the touched geometry, as a fraction of the
    /// scene radius: the redistribution has to reach the RING OF NEIGHBOURS
    /// of what was just authored, not only the authored vertices.
    static let autoRelaxPadFraction: Float = 0.12
    /// Deliberately gentler than the Relax verb (`relaxStrength` 0.35): the
    /// pass runs after EVERY operation, so a strong sweep would drag the
    /// cage away from what the user drew.
    static let autoRelaxStrength: Float = 0.2

    /// Brush the Auto Relax pass runs over: centred on the touched points
    /// with a radius covering them plus a neighbour ring. nil when there is
    /// nothing to relax around.
    struct AutoRelaxBrush: Equatable {
        var center: SIMD3<Float>
        var radius: Float
    }

    /// Pure neighbourhood math (unit-tested headless).
    static func autoRelaxBrush(
        around points: [SIMD3<Float>], sceneRadius: Float
    ) -> AutoRelaxBrush? {
        guard !points.isEmpty else { return nil }
        var center = SIMD3<Float>.zero
        for point in points { center += point }
        center /= Float(points.count)
        let extent = points.reduce(Float(0)) { max($0, simd_distance($1, center)) }
        let pad = max(sceneRadius, 1e-6) * autoRelaxPadFraction
        return AutoRelaxBrush(center: center, radius: extent + pad)
    }

    /// Runs the Auto Relax pass when the mode is on — CALLED FROM INSIDE the
    /// triggering operation's transaction, so it lands in that operation's
    /// single journal entry.
    ///
    /// Pins ride along on the engine call (spec: "honoring pins"), and
    /// corner auto-pinning keeps regular patch shapes from rounding off.
    /// Throwing propagates into `journalOrDiscard`, which discards the live
    /// edits rather than journaling a half-applied operation.
    func runAutoRelaxIfEnabled(
        mesh: Mesh, context: Context, around points: [SIMD3<Float>]
    ) throws {
        guard autoRelaxEnabled,
            let brush = Self.autoRelaxBrush(
                around: points, sceneRadius: context.sceneRadius
            )
        else { return }
        try mesh.relax(
            around: brush.center,
            radius: brush.radius,
            strength: Self.autoRelaxStrength,
            pinned: context.annotations?.pinnedVertices ?? [],
            snapping: context.snapper
        )
    }

    /// World positions of the elements a grammar candidate addresses — the
    /// neighbourhood its Auto Relax pass runs over. Face elements
    /// contribute nothing (the engine exposes no face-centroid query), so
    /// face-only operations get no Auto Relax pass; see tasks.md 4.5a.
    func autoRelaxPoints(
        of elements: [StrokeInterpretation.Element], mesh: Mesh?
    ) -> [SIMD3<Float>] {
        guard let mesh else { return [] }
        var points: [SIMD3<Float>] = []
        for element in elements {
            switch element.kind {
            case .vertex:
                if let position = mesh.vertexPosition(element.id) { points.append(position) }
            case .edge:
                guard let ends = mesh.edgeEndpoints(of: element.id) else { continue }
                for vertex in [ends.0, ends.1] {
                    if let position = mesh.vertexPosition(vertex) { points.append(position) }
                }
            case .face:
                continue
            }
        }
        return points
    }

    // MARK: - Batch commands

    /// Runs one batch command against the CURRENT document state,
    /// journaling exactly one undoable entry. Returns whether anything
    /// journaled — a no-op (already snapped, nothing to clear) stays out of
    /// the undo stack entirely, which is what the panel disables itself on.
    @discardableResult
    func runBatchCommand(_ command: BatchCommand) -> Bool {
        switch command {
        case .clearLoopTags:
            return clearAllLoopTags()
        case .clearPins:
            return clearAllPins()
        case .snapAllToTarget:
            return runBatchMeshEdit(command) { mesh, context in
                let report = try mesh.snapAllToTarget(
                    context.snapper, pinned: context.annotations?.pinnedVertices ?? []
                )
                self.onCameraToolStatus?(
                    Self.snapAllStatus(report)
                )
            }
        case .relaxAll:
            return runBatchMeshEdit(command) { mesh, context in
                try mesh.relaxAll(
                    pinned: context.annotations?.pinnedVertices ?? [],
                    snapping: context.snapper
                )
            }
        case .subdivide:
            return runBatchMeshEdit(command) { mesh, _ in
                try mesh.subdivide()
            }
        case .subdivideAndReproject:
            return runBatchMeshEdit(command) { mesh, context in
                try mesh.subdivide(reprojectingOnto: context.snapper)
            }
        case .triangulate:
            return runBatchMeshEdit(command) { mesh, _ in
                try mesh.triangulate()
            }
        }
    }

    static func snapAllStatus(_ report: Mesh.ResnapReport) -> String {
        guard report.resnapped > 0 else { return "Already on the Target" }
        let gap = String(format: "%.3f", report.maxDistance)
        return "Snapped \(report.resnapped) vertices to the Target (max \(gap))"
    }

    /// Shared epilogue for the geometry batch commands: runs `body` inside
    /// ONE `MeshEditTransaction` and journals a single entry — a plain
    /// `meshEdit` when the operation preserves element ids, or a
    /// `compound` pairing it with the `annotationEdit` that drops the
    /// annotations the operation just orphaned.
    private func runBatchMeshEdit(
        _ command: BatchCommand, _ body: (Mesh, Context) throws -> Void
    ) -> Bool {
        // A whole-mesh command must never bake an armed session's
        // uncommitted live edits into its own journal entry.
        guard allowsWholeMeshCommand() else { return false }
        guard let context = contextProvider?(), let object = context.editObject,
            let mesh = context.editMesh, let payload = context.editPayload
        else { return false }
        guard !command.requiresTarget || context.snapper != nil else {
            Self.batchLog.error("\(command.rawValue) needs an active Target")
            return false
        }
        let verb = "batch.\(command.rawValue)"
        let transaction = MeshEditTransaction(
            object: object, mesh: mesh, currentPayload: payload
        )
        let policy = command.annotationPolicy
        lastCommit = nil
        journalOrDiscard(verb: verb) {
            try body(mesh, context)
            onLiveEdit?()
            // ONE user-visible step: the transaction pairs the geometry
            // with the annotations the operation orphaned (this command's
            // `AnnotationIDPolicy` for the full-rebuild ops, PLUS the
            // payload round trip's id compaction for the rest) into a
            // single compound entry, so one undo restores both together.
            return try transaction.command(verb: verb) { policy.surviving($0) }
        }
        return lastCommit != nil
    }

    // MARK: - Visual-verification probe (task 4.5 screenshot hook)

    /// Subdivides the seeded cage through the real journaled batch path so
    /// the screenshot shows a genuinely denser wireframe. Returns whether
    /// the command journaled.
    @discardableResult
    func probeBatchSubdivideForVisualVerification() -> Bool {
        runBatchCommand(.subdivideAndReproject)
    }
}

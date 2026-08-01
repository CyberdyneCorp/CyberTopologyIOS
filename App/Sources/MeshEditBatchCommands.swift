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
    /// add-halve-density: the counterpart to Subdivide.
    case halve
    case triangulate
    case clearLoopTags
    case clearPins
    /// add-weave-constraint-authoring: thaw every frozen face.
    case clearFrozen
    /// add-uv-seam-authoring: sew every UV seam.
    case clearSeams

    var id: String { rawValue }

    var title: String {
        switch self {
        case .snapAllToTarget: "Snap All to Target"
        case .relaxAll: "Relax All"
        case .subdivide: "Subdivide"
        case .subdivideAndReproject: "Subdivide + Reproject"
        case .halve: "Halve"
        case .triangulate: "Triangulate"
        case .clearLoopTags: "Clear Loop Tags"
        case .clearPins: "Clear Pins"
        case .clearFrozen: "Clear Frozen"
        case .clearSeams: "Clear Seams"
        }
    }

    var symbol: String {
        switch self {
        case .snapAllToTarget: "arrow.down.to.line"
        case .relaxAll: "wind"
        case .subdivide: "square.grid.2x2"
        case .subdivideAndReproject: "square.grid.3x3.square"
        case .halve: "square.split.2x2"
        case .triangulate: "triangle"
        case .clearLoopTags: "tag.slash"
        case .clearPins: "pin.slash"
        case .clearFrozen: "snowflake.slash"
        case .clearSeams: "scissors.badge.ellipsis"
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
        case .halve:
            "Halves the cage: every other edge loop is dissolved, so each 2x2 "
                + "block becomes one quad. The silhouette does not move. Refuses on "
                + "cages where 'every other loop' has no answer. Clears pins and tags."
        case .triangulate:
            "Splits every quad and n-gon into triangles. Pins survive; "
                + "loop tags and hidden faces are cleared."
        case .clearLoopTags:
            "Removes every loop tag in one undoable step."
        case .clearPins:
            "Removes every pin in one undoable step."
        case .clearFrozen:
            "Thaws every frozen face in one undoable step, so the next Weave "
                + "solve is free to rewrite them again."
        case .clearSeams:
            "Sews every UV seam in one undoable step, so the next unwrap chooses "
                + "its own seams again."
        }
    }

    /// Whether a selected patch scopes this command (openspec
    /// add-patch-selection-scope). The three that do not are the ones that cannot
    /// be scoped without damaging the cage — see `wholeCageOnly`.
    var scopesToSelection: Bool {
        switch self {
        case .subdivide, .subdivideAndReproject, .halve: false
        default: true
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
        case .subdivide, .subdivideAndReproject, .halve: .rebuilt
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
    /// neighbourhood its Auto Relax pass runs over. Face elements resolve to
    /// their ring vertices (engine `faceVertices` query, task 4.5a), so a
    /// face-only op like X-delete now redistributes the topology around the
    /// hole it left.
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
                for vertex in mesh.faceVertices(element.id) {
                    if let position = mesh.vertexPosition(vertex) { points.append(position) }
                }
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
        // Subdivide and Halve cannot scope to a patch without leaving non-quads
        // where the patch meets its neighbours, or a half-dissolved loop hanging
        // past the boundary. They run on the whole cage and SAY so, because a
        // selection silently ignored is worse than one honestly declined.
        if !selectedPatch.isEmpty, !command.scopesToSelection {
            pendingStatusNote = Self.wholeCageOnly(command)
        }
        // Whatever the command reports, the note travels WITH it. Reported
        // separately, the note was overwritten before it could be read: a halve
        // that declined showed only the refusal, so the artist could not tell
        // their selection had been ignored too.
        defer { flushPendingStatusNote() }
        switch command {
        case .clearLoopTags:
            guard let edges = scopedEdges() else { return clearAllLoopTags() }
            return applyAnnotationEditNow(verb: "batch.clearLoopTags") {
                $0.clearingTags(on: edges)
            }
        case .clearPins:
            guard let scope = selectionScope() else { return clearAllPins() }
            return applyAnnotationEditNow(verb: "batch.clearPins") {
                $0.clearingPins(on: scope.vertices)
            }
        case .clearFrozen:
            guard !selectedPatch.isEmpty else { return clearAllFrozen() }
            let faces = selectedPatch
            return applyAnnotationEditNow(verb: "batch.clearFrozen") {
                $0.clearingFrozen(on: faces)
            }
        case .clearSeams:
            guard let edges = scopedEdges() else { return clearAllSeams() }
            let set = Set(edges)
            return applyAnnotationEditNow(verb: "batch.clearSeams") {
                $0.clearingSeams(on: set)
            }
        case .snapAllToTarget:
            return runBatchMeshEdit(command) { mesh, context in
                let report = try mesh.snapAllToTarget(
                    context.snapper, pinned: self.holdingEverythingOutside(mesh, context)
                )
                self.reportStatus(Self.snapAllStatus(report))
            }
        case .relaxAll:
            return runBatchMeshEdit(command) { mesh, context in
                try mesh.relaxAll(
                    pinned: self.holdingEverythingOutside(mesh, context),
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
        case .halve:
            return runBatchMeshEdit(command) { mesh, _ in
                do {
                    let report = try mesh.halveDensity()
                    self.reportStatus(Self.halveStatus(report))
                } catch let failure as Mesh.HalveDensityFailure {
                    // A refusal is an ANSWER, not a crash: say which rule declined
                    // and rethrow so the transaction is discarded byte-clean.
                    self.reportStatus(Self.halveRefusal(failure, in: mesh))
                    // ONE triangle in a 317-face cage is a needle, and naming the
                    // count does not locate it. Selecting the offenders puts them
                    // on screen in gold — the selection is replaced because the
                    // one being held was about to be ignored anyway.
                    if case .notQuadOnly = failure {
                        self.selectFaces(Self.nonQuadFaces(in: mesh))
                    }
                    throw failure
                }
            }
        case .triangulate:
            return runBatchMeshEdit(command) { mesh, _ in
                guard !self.selectedPatch.isEmpty else {
                    try mesh.triangulate()
                    return
                }
                try Self.triangulate(self.selectedPatch, in: mesh)
            }
        }
    }

    /// Fan-triangulates just `faces`.
    ///
    /// Builds every triangle BEFORE deleting the faces they replace: adding a
    /// face leaves existing ids alone, while deleting compacts them, so the other
    /// order would invalidate the very ids this is working from. The deletion is
    /// one sorted call for the same reason a region carve is — an unsorted list
    /// made the solve non-deterministic once already.
    static func triangulate(_ faces: Set<UInt32>, in mesh: Mesh) throws {
        var doomed: [UInt32] = []
        for face in faces.sorted() {
            let ring = mesh.faceVertices(face)
            guard ring.count > 3 else { continue }
            for corner in 1..<(ring.count - 1) {
                _ = try mesh.buildFace(ring: [
                    .existing(ring[0]), .existing(ring[corner]), .existing(ring[corner + 1]),
                ])
            }
            doomed.append(face)
        }
        guard !doomed.isEmpty else { return }
        try mesh.deleteFaces(doomed.sorted())
    }

    /// The selection's vertices and the edges lying inside it.
    ///
    /// An edge counts as inside when BOTH its endpoints are: an edge with one end
    /// outside is the patch's border, and clearing a tag there would change the
    /// topology the artist can see beyond what they selected.
    func selectionScope() -> (vertices: Set<UInt32>, mesh: Mesh)? {
        guard !selectedPatch.isEmpty, let mesh = contextProvider?()?.editMesh else { return nil }
        var vertices: Set<UInt32> = []
        for face in selectedPatch { vertices.formUnion(mesh.faceVertices(face)) }
        return vertices.isEmpty ? nil : (vertices, mesh)
    }

    /// Annotated edges lying inside the selection, or nil when nothing is
    /// selected (so the caller falls back to the whole cage).
    private func scopedEdges() -> [UInt32]? {
        guard let scope = selectionScope(), let annotations = contextProvider?()?.annotations
        else { return nil }
        let candidates = Set(annotations.taggedEdges).union(annotations.seamEdges)
        return candidates.filter { edge in
            guard let ends = scope.mesh.edgeEndpoints(of: edge) else { return false }
            return scope.vertices.contains(ends.0) && scope.vertices.contains(ends.1)
        }
    }

    /// The pin set that confines a whole-mesh op to the selection: everything
    /// OUTSIDE it, plus the artist's own pins.
    ///
    /// Scoping by pinning rather than by a new engine entry point, because the
    /// engine already honours a pin set and the border behaviour that falls out
    /// is the correct one — the patch smooths or snaps while the cage around it
    /// holds still, which is what selecting a patch meant.
    func holdingEverythingOutside(_ mesh: Mesh, _ context: Context) -> [UInt32] {
        let authored = context.annotations?.pinnedVertices ?? []
        guard let scope = selectionScope() else { return authored }
        return mesh.liveVertexIDs().subtracting(scope.vertices).union(authored).sorted()
    }

    /// Why a command ignored the selection.
    static func wholeCageOnly(_ command: BatchCommand) -> String {
        switch command {
        case .halve:
            return "Halve runs on the whole cage: an edge loop does not stop at a "
                + "patch boundary, so halving one partway leaves a hanging half-loop"
        default:
            return "\(command.title) runs on the whole cage: subdividing one patch "
                + "would leave n-gons where it meets its neighbours"
        }
    }

    /// What a halve did, including the case where only ONE grid direction could
    /// be halved — the artist should not have to work out why the count did not
    /// quarter.
    static func halveStatus(_ report: Mesh.HalvedDensity) -> String {
        let base = "Halved: \(report.facesBefore) quads -> \(report.facesAfter)"
        guard report.directionsHalved == 1 else { return base }
        return base + " (one direction only — the other has an odd number of quads "
            + "across, so its last loop is the boundary)"
    }

    /// Faces that are not quads — what a Halve refusal points at.
    static func nonQuadFaces(in mesh: Mesh) -> Set<UInt32> {
        Set(mesh.liveFaceIDs().filter { mesh.faceVertices($0).count != 4 })
    }

    /// A note that must survive whatever the command reports next, so the two
    /// arrive as one message instead of the second replacing the first.
    private var pendingStatusNote: String? {
        get { pendingStatusNoteStorage }
        set { pendingStatusNoteStorage = newValue }
    }

    func reportStatus(_ message: String) {
        if let note = pendingStatusNote {
            pendingStatusNote = nil
            onCameraToolStatus?("\(note). \(message)")
        } else {
            onCameraToolStatus?(message)
        }
    }

    /// Emits a note no command consumed — a command that scoped away silently
    /// still owes the artist an explanation.
    func flushPendingStatusNote() {
        guard let note = pendingStatusNote else { return }
        pendingStatusNote = nil
        onCameraToolStatus?(note)
    }

    /// Why a halve declined, NAMING what is in the way.
    ///
    /// "Needs an all-quad cage" told the artist the rule but not the state, on a
    /// 315-face cage where the offending faces are a handful somewhere in the
    /// middle. The counts turn it into something actionable.
    static func halveRefusal(_ failure: Mesh.HalveDensityFailure, in mesh: Mesh) -> String {
        guard case .notQuadOnly = failure, let stats = try? mesh.stats() else {
            return halveRefusal(failure)
        }
        var offenders: [String] = []
        if stats.triangles > 0 {
            offenders.append("\(stats.triangles) triangle\(stats.triangles == 1 ? "" : "s")")
        }
        if stats.other > 0 {
            offenders.append("\(stats.other) n-gon\(stats.other == 1 ? "" : "s")")
        }
        guard !offenders.isEmpty else { return halveRefusal(failure) }
        return "Halve needs an all-quad cage — this one has "
            + offenders.joined(separator: " and ")
            + ", now selected so you can find "
            + (stats.triangles + stats.other == 1 ? "it" : "them")
    }

    /// Why a halve declined, in the artist's terms — the panel shows this instead
    /// of the command silently doing nothing.
    static func halveRefusal(_ failure: Mesh.HalveDensityFailure) -> String {
        switch failure {
        case .noCage:
            "Nothing to halve"
        case .notQuadOnly:
            "Halve needs an all-quad cage (a triangle or n-gon has no loops to halve)"
        case .notGridRegular:
            "Halve needs regular grid topology — a pole stops a loop partway across"
        case .noBoundary:
            "Halve needs an open cage: a closed one has no side to start from"
        case .tooFewCells:
            "Too few quads across to halve"
        case .oddCellCount:
            "Halve needs an even number of quads across, or 'every other loop' has no answer"
        case .strandedMidVertex:
            "Halve could not reduce this cage cleanly, so nothing changed"
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

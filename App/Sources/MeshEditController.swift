import CyberKit
import CyberKitTesting
import Foundation
import os
import simd

/// Applies the five RT verbs to the live EditMesh (task 3.3; specs:
/// pencil-interaction / "Five coherent verbs across stages",
/// retopology-tools, document-model / "EditMesh vertex snapping").
///
/// The controller sits between the stroke capture (which forwards begin /
/// sample / end / cancel events via `ViewportInputModel`) and the document:
///
///   - **Pencil** strokes do nothing while in flight; at stroke end the
///     engine recognizer's interpretation record is consulted, and a best
///     `createQuad` executes — the record's corner estimates are unprojected
///     through the camera onto the Target and the engine creates the face
///     with continuous snap projection.
///   - **Relax / Move / Tweak / Erase** are live sessions: each sample
///     applies an engine operation to the live mesh (overlay refreshes via
///     `onLiveEdit`), and the whole scrub is journaled as ONE
///     `DocumentCommand.meshEdit` at stroke end via `MeshEditTransaction`
///     (exact before/after payloads — no tool mutates outside a journaled
///     command). Cancelled strokes discard the live edits
///     (`onDiscardLiveEdits` reloads the mesh from the document payload).
///
/// All mesh algorithms run engine-side (design D1); the only geometry here
/// is camera unprojection, which belongs to the shell-owned camera.
@MainActor
final class MeshEditController {
    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "CyberTopology", category: "mesh-edit"
    )

    /// A camera ray in world space.
    typealias Ray = (origin: SIMD3<Float>, direction: SIMD3<Float>)

    /// Everything a verb needs, fetched fresh at stroke begin so sessions
    /// always act on the CURRENT document state and camera.
    struct Context {
        /// Manifest entry of the EditMesh (nil = document has none yet).
        var editObject: DocumentManifest.Object?
        /// Live engine mesh for `editObject` (the same handle the overlay
        /// and recognizer use).
        var editMesh: Mesh?
        /// `editObject`'s payload bytes as stored in the document right now
        /// (pinned by the transaction for byte-exact revert).
        var editPayload: Data?
        /// True when the document manifest contains an EditMesh object at
        /// all — even when `editObject`/`editMesh`/`editPayload` are nil
        /// because the snapshot is unusable (payload failed to
        /// deserialize). Guards the pencil create-first-quad fallback: a
        /// second `.editMesh` object must never be journaled.
        var documentHasEditMesh = false
        /// Target surface snapper; the brush verbs and quad creation
        /// require a Target (spec: EditMesh vertices snap to the ACTIVE
        /// Target; without one there is no surface to anchor a brush to).
        var snapper: SurfaceSnapper?
        /// Scene bounding radius — brush radii scale with it.
        var sceneRadius: Float
        /// Normalized viewport point -> world ray through the camera.
        var ray: (SIMD2<Float>) -> Ray?
        /// World position -> normalized viewport point (the inverse of
        /// `ray`; nil when unavailable). The task-4.1 tool screenshot
        /// probes derive stroke points from live mesh elements with it.
        var project: ((SIMD3<Float>) -> SIMD2<Float>?)? = nil
        /// Current camera pose (task 4.2): the camera-as-manipulator
        /// sessions pin the view matrix at selection time and compute
        /// placement against the latest pose at commit.
        var camera: CameraState? = nil
        /// Orbits the LIVE viewport camera by screen points (task 4.2
        /// probes: the camera-tool screenshot hooks must move the real
        /// camera the session and the frame both read; nil headless).
        var orbitCamera: ((SIMD2<Float>) -> Void)? = nil
    }

    /// How a completed Pencil stroke resolved (task 3.5: drives the
    /// post-stroke interpretation chip). Published for EVERY pencil stroke
    /// end — recognized-and-applied, recognized-but-inert, and unrecognized
    /// alike (the spec chip shows rejected strokes too).
    struct PencilStrokeOutcome: Equatable {
        /// The engine recognizer's record (nil = recognition failed).
        var interpretation: StrokeInterpretation?
        /// Candidate index that applied AND journaled; nil = the stroke
        /// changed nothing.
        var appliedIndex: Int?
        /// Candidate indices offered as one-tap swaps
        /// (`applyAlternative(at:)` accepts exactly these).
        var alternatives: [Int]
    }

    var contextProvider: (() -> Context?)?
    /// Journal sink: every finished mutation arrives here as one command.
    var onCommit: ((DocumentCommand) -> Void)?
    /// Chip sink (task 3.5): fired once per completed Pencil stroke with
    /// how it resolved.
    var onPencilStrokeResolved: ((PencilStrokeOutcome) -> Void)?
    /// Alternative-swap sink (task 3.5): `(replacement, expected current)`.
    /// The document must atomically revert the expected command, apply the
    /// replacement, and swap the journal entry IN PLACE (exactly one entry
    /// after the swap, no extra undo step) — or report false untouched when
    /// the journal moved on (stale chip).
    var onReplaceCommit: ((DocumentCommand, DocumentCommand) -> Bool)?
    /// Live (not yet journaled) mutation happened: refresh the overlay from
    /// the live mesh.
    var onLiveEdit: (() -> Void)?
    /// Live edits must be thrown away (cancelled stroke / failed commit):
    /// reload the live mesh from the document payload.
    var onDiscardLiveEdits: (() -> Void)?
    /// A gesture asked for a verb switch (task 3.4: double-tap on a vertex
    /// activates Tweak, CozyBlanket-style); the input model routes it into
    /// the arbiter so the toolbar highlight follows.
    var onRequestVerb: ((InputArbiter.Verb) -> Void)?
    /// Snap pre-highlight sink (task 3.7, spec scenario "Snap feedback"):
    /// the coordinator renders/clears the snap-target highlight through the
    /// overlay's highlight pass. nil = clear. Fires BEFORE any commit.
    var onSnapHighlightChanged: ((HoverPreviewState.SnapTarget?) -> Void)?
    /// Injected haptic seam (task 3.7): nil = silent. Tests inject a
    /// recording fake; the coordinator installs the capability-gated
    /// `SnapHapticsEngine` (graceful no-op on simulator).
    var haptics: SnapHapticsPlaying?

    // Brush sizing as fractions of the scene radius. Values chosen for the
    // CozyBlanket-like feel at typical cage density; user-facing brush size
    // controls arrive with the full toolbar (task 3.8).
    static let relaxRadiusFraction: Float = 0.18
    static let moveRadiusFraction: Float = 0.3
    static let eraseBaseRadiusFraction: Float = 0.08
    static let vertexPickRadiusFraction: Float = 0.12
    static let relaxStrength: Float = 0.35
    /// Merge-snap range (task 3.7): how close the DRAGGED vertex must come
    /// to another vertex for the snap target to pre-highlight and the
    /// stroke-end merge/snap to engage. Deliberately much tighter than the
    /// grab radius so ordinary tweaks near neighbors do not merge.
    static let mergeSnapRadiusFraction: Float = 0.04

    /// Snap-feedback mapping (task 3.7): pure event → highlight/tick state,
    /// fed by the Tweak/Move snap detection below. `hapticsEnabled` is the
    /// user's setting (spec: haptics SHALL be user-disableable — disabling
    /// silences ticks only, never the highlight or the merge itself).
    private(set) var snapFeedback = SnapFeedbackState()
    var snapHapticsEnabled: Bool {
        get { snapFeedback.hapticsEnabled }
        set { snapFeedback.hapticsEnabled = newValue }
    }
    /// Last brush sample in normalized viewport coordinates (anchors the
    /// haptic tick's screen location for Pencil Pro canvas routing).
    private var lastBrushPoint: SIMD2<Float>?

    /// Routes snap-feedback effects to their sinks.
    private func emitSnapEffects(_ effects: [SnapFeedbackState.Effect]) {
        for effect in effects {
            switch effect {
            case .showHighlight(let target):
                onSnapHighlightChanged?(target)
            case .clearHighlight:
                onSnapHighlightChanged?(nil)
            case .tick(let tick):
                haptics?.play(tick, atNormalized: lastBrushPoint.map {
                    CGPoint(x: Double($0.x), y: Double($0.y))
                })
            }
        }
    }

    private struct Session {
        var verb: InputArbiter.Verb
        var context: Context
        var transaction: MeshEditTransaction
        /// Vertex grabbed at stroke start (Move seed / Tweak target).
        var grabbedVertex: UInt32?
        /// Last surface point of the drag (Move displacement anchor).
        var anchor: SIMD3<Float>?
        var mutated = false
    }

    private var session: Session?

    /// True while a session holds live (not yet journaled) mesh state a
    /// document resync would clobber: a brush-verb scrub, or a Transform
    /// Vertices camera session (task 4.2 — its camera feed mutates the
    /// live mesh ahead of the journal exactly like a brush drag).
    var isSessionActive: Bool { session != nil || cameraSessionHoldsLiveMesh }

    // MARK: - Retopology tools (task 4.1)

    /// Armed build tool (Build Quad / Build Triangle / Merge Pair / Path
    /// Distribute / Surface Cut): while set, Pencil-verb strokes drive the
    /// tool instead of the gesture grammar (spring-loaded verb holds still
    /// override for their duration — their strokes arrive with the held
    /// verb). Set by `ViewportInputModel.selectTool`; selecting any verb
    /// disarms.
    var activeTool: RetopoTool?
    /// In-flight tool stroke (context pinned at stroke begin; the raw
    /// polyline arrives with `strokeEnded`). The tools mutate ONLY at
    /// stroke end, so cancellation just drops this state.
    var toolStroke: ToolStroke?

    // MARK: - Camera-as-manipulator sessions (task 4.2)

    /// Active camera-as-manipulator session (Patch Clone / Extend
    /// Boundary / Transform Vertices): a selection stroke arms it, camera
    /// deltas drive it (routed through the InputArbiter), commit journals
    /// ONCE, cancel discards. See `MeshEditCameraTools.swift`.
    var cameraSession: CameraToolSession?
    /// Sticky Extend Boundary mode across selections (banner picker).
    var preferredExtendBoundaryMode: ExtendBoundaryPlan.Mode = .single
    /// Session banner sink (nil = no session): the input model publishes
    /// it for the editor overlay AND arms the arbiter's camera→tool feed.
    var onCameraSessionChanged: ((CameraToolBanner?) -> Void)?
    /// Session ghost-preview sink (task 4.2: previews render as ghost
    /// geometry, never a committed mutation). nil = clear.
    var onSessionPreviewChanged: ((HoverRenderState.GhostQuad?) -> Void)?
    /// Transient status line sink (the Transform Vertices re-snap report).
    var onCameraToolStatus: ((String) -> Void)?
    /// Last Transform Vertices re-snap report (spec: "re-snap report").
    private(set) var lastResnapReport: Mesh.ResnapReport?

    func recordResnapReport(_ report: Mesh.ResnapReport) {
        lastResnapReport = report
    }

    /// Everything an alternative swap needs, captured when a Pencil stroke
    /// applies (task 3.5). The replacement command is rebuilt from the
    /// PRE-stroke snapshot (payload bytes, manifest entry, annotations) on
    /// a scratch mesh — candidate element ids reference the pre-stroke
    /// topology, so applying them to the byte-exact before-payload is the
    /// only correct base.
    private struct AppliedPencilStroke {
        var interpretation: StrokeInterpretation
        var appliedIndex: Int
        /// The command as journaled (the swap's expected-current guard).
        var command: DocumentCommand
        /// Manifest entry BEFORE the stroke (counts/revision/annotations).
        var object: DocumentManifest.Object
        /// Payload bytes BEFORE the stroke.
        var beforePayload: Data
        var beforeAnnotations: MeshAnnotations?
        /// Stroke-time unprojection of the record's corner estimates (a
        /// createQuad alternative must land where the STROKE was drawn,
        /// not where the camera points at swap time).
        var worldCorners: [SIMD3<Float>]?
    }

    private var lastApplied: AppliedPencilStroke?
    /// Command committed by the most recent apply path (set by `send`).
    /// Internal (not private): the task-4.1 tool probes reset and read it
    /// to report whether a driven stroke actually journaled.
    var lastCommit: DocumentCommand?

    /// Every commit funnels through here so the pencil apply paths can
    /// observe whether a command actually reached the journal.
    private func send(_ command: DocumentCommand) {
        lastCommit = command
        onCommit?(command)
    }

    // MARK: - Stroke events (forwarded by ViewportInputModel)

    func strokeBegan(verb: InputArbiter.Verb, sample: StrokeSample) {
        session = nil
        toolStroke = nil
        // A new stroke invalidates the chip's swap context (the chip itself
        // dismisses on stroke begin; the expected-command guard would also
        // reject a stale swap, this just keeps the states aligned)…
        lastApplied = nil
        // …and clears any leftover snap highlight (task 3.7; idempotent —
        // the end/cancel paths already clear it).
        emitSnapEffects(snapFeedback.strokeCancelled())
        lastBrushPoint = point(of: sample)
        if verb == .pencil {
            // Armed tool (task 4.1): pin the context now — the stroke must
            // act on the document state and camera it started over. Tools
            // need an existing EditMesh and a Target to unproject onto;
            // without either the stroke stays inert.
            if let tool = activeTool,
                let context = contextProvider?(),
                context.editObject != nil, context.editMesh != nil,
                context.editPayload != nil, context.snapper != nil {
                toolStroke = ToolStroke(tool: tool, context: context)
            }
            return  // interpreted (grammar) or committed (tool) at stroke end
        }
        guard
            let context = contextProvider?(),
            let object = context.editObject,
            let mesh = context.editMesh,
            let payload = context.editPayload,
            context.snapper != nil
        else { return }

        var newSession = Session(
            verb: verb,
            context: context,
            transaction: MeshEditTransaction(
                object: object, mesh: mesh, currentPayload: payload
            )
        )
        if verb == .move || verb == .tweak {
            // Grab the vertex nearest to where the stroke lands on the
            // surface; a miss leaves the whole stroke inert.
            guard
                let hit = surfacePoint(at: point(of: sample), in: context),
                let pick = mesh.nearestVertex(
                    to: hit, maxDistance: context.sceneRadius * Self.vertexPickRadiusFraction
                )
            else { return }
            newSession.grabbedVertex = pick.vertex
            newSession.anchor = hit
        }
        session = newSession
        if verb == .relax || verb == .erase {
            applyBrush(at: sample)
        }
    }

    func strokeContinued(sample: StrokeSample) {
        guard session != nil else { return }
        applyBrush(at: sample)
    }

    /// Stroke finished: commit the brush session, or interpret-and-apply a
    /// Pencil stroke through the full gesture grammar (tasks 3.3/3.4).
    /// `samples` is the raw captured polyline — the grammar entries that
    /// depend on stroke direction (visibility lines) or tap position
    /// (double-tap) read it; interpretation-only entries ignore it.
    func strokeEnded(
        verb: InputArbiter.Verb, interpretation: StrokeInterpretation?,
        samples: [StrokeSample] = []
    ) {
        if let finished = session {
            session = nil
            commit(finished)
            return
        }
        if let stroke = toolStroke {
            toolStroke = nil
            if verb == .pencil {
                commitToolStroke(stroke, samples: samples)
            }
            return
        }
        guard verb == .pencil else { return }
        let outcome = applyPencilInterpretation(interpretation, samples: samples)
        onPencilStrokeResolved?(outcome)
    }

    func strokeCancelled() {
        emitSnapEffects(snapFeedback.strokeCancelled())
        // Tool strokes mutate only at commit: cancellation drops the
        // pinned context and nothing else.
        toolStroke = nil
        guard let cancelled = session else { return }
        session = nil
        if cancelled.mutated {
            onDiscardLiveEdits?()
        }
    }

    // MARK: - Brush application

    private func applyBrush(at sample: StrokeSample) {
        guard let current = session else { return }
        let context = current.context
        guard
            let mesh = context.editMesh,
            let hit = surfacePoint(at: point(of: sample), in: context)
        else { return }
        let radiusBase = context.sceneRadius
        do {
            switch current.verb {
            case .relax:
                try mesh.relax(
                    around: hit,
                    radius: radiusBase * Self.relaxRadiusFraction,
                    strength: Self.relaxStrength,
                    snapping: context.snapper
                )
            case .erase:
                try mesh.erase(
                    around: hit,
                    baseRadius: radiusBase * Self.eraseBaseRadiusFraction,
                    pressure: Float(sample.pressure)
                )
            case .move:
                guard let seed = current.grabbedVertex, let anchor = current.anchor,
                    mesh.vertexPosition(seed) != nil
                else { return }
                let displacement = hit - anchor
                guard simd_length(displacement) > 0 else { return }
                try mesh.moveWithGeodesicFalloff(
                    seed: seed,
                    displacement: displacement,
                    radius: radiusBase * Self.moveRadiusFraction,
                    snapping: context.snapper
                )
                session?.anchor = hit
            case .tweak:
                guard let vertex = current.grabbedVertex else { return }
                try mesh.tweakVertex(vertex, to: hit, snapping: context.snapper)
            case .pencil:
                return
            }
            session?.mutated = true
            lastBrushPoint = point(of: sample)
            updateSnapDetection(for: current, mesh: mesh)
            onLiveEdit?()
        } catch {
            Self.log.error("verb \(current.verb.rawValue) failed: \(String(describing: error))")
        }
    }

    /// Merge-snap detection (task 3.7, spec scenario "Snap feedback"): when
    /// the DRAGGED vertex (Tweak target / Move seed) sits within merge
    /// range of another vertex, that target pre-highlights — before
    /// anything commits — and `commit` finalizes the merge/snap at stroke
    /// end. Engine-side query (design D1) excluding the dragged vertex
    /// itself (which is always nearest to its own position).
    private func updateSnapDetection(for current: Session, mesh: Mesh) {
        guard current.verb == .tweak || current.verb == .move,
            let grabbed = current.grabbedVertex
        else { return }
        var candidate: HoverPreviewState.SnapTarget?
        if let dragged = mesh.vertexPosition(grabbed),
            let pick = mesh.nearestVertex(
                to: dragged,
                maxDistance: current.context.sceneRadius * Self.mergeSnapRadiusFraction,
                excluding: grabbed
            ) {
            candidate = HoverPreviewState.SnapTarget(
                vertex: pick.vertex, position: pick.position
            )
        }
        emitSnapEffects(snapFeedback.dragUpdated(candidate: candidate))
    }

    private func commit(_ finished: Session) {
        guard finished.mutated else {
            emitSnapEffects(snapFeedback.strokeEnded(committed: false))
            return
        }
        // Merge-snap finalization (task 3.7): a snap candidate held at
        // stroke end commits INSIDE the same journaled transaction —
        // exactly one journal entry for grab + drag + merge. Tweak merges
        // the dragged vertex into the target (topology change, the spec's
        // "merge" event); Move welds the SEED's position exactly onto the
        // target vertex without merging topology (the region kept its
        // structure — collapsing it under a whole-falloff drag would be
        // surprising; the spec's "vertex snap" event).
        let candidate = snapFeedback.candidate
        var verb = finished.verb.rawValue
        lastCommit = nil
        journalOrDiscard(verb: verb) {
            if let candidate, let grabbed = finished.grabbedVertex,
                let mesh = finished.context.editMesh {
                switch finished.verb {
                case .tweak:
                    try mesh.mergeVertices(keep: candidate.vertex, remove: grabbed)
                    verb += ".mergeSnap"
                case .move:
                    try mesh.tweakVertex(grabbed, to: candidate.position)
                    verb += ".vertexSnap"
                default:
                    break
                }
                onLiveEdit?()
            }
            return try finished.transaction.command(verb: verb)
        }
        // Tick ON commit (highlight was live during the drag): only when
        // a snap/merge was engaged AND its command reached the journal.
        let snapCommitted = candidate != nil && verb != finished.verb.rawValue
            && lastCommit != nil
        emitSnapEffects(snapFeedback.strokeEnded(committed: snapCommitted))
    }

    /// The single journaling epilogue for every path that mutated the LIVE
    /// mesh (brush-session commit AND the pencil quad append): builds the
    /// command and hands it to `onCommit`. When `makeCommand` throws, the
    /// live mesh has diverged from the document with no journal entry — the
    /// live edits are discarded (`onDiscardLiveEdits` reloads from the
    /// document payload) rather than letting the overlay and the document
    /// silently drift apart (byte-exact revert would otherwise break: the
    /// next stroke would pin the stale document payload as `before` while
    /// serializing the diverged live mesh as `after`).
    ///
    /// Internal (not private) so the failure path is unit-testable: a
    /// serialization failure cannot be forced through a real engine mesh.
    func journalOrDiscard(verb: String, makeCommand: () throws -> DocumentCommand?) {
        do {
            if let command = try makeCommand() {
                send(command)
            }
        } catch {
            Self.log.error(
                "mesh edit commit (\(verb)) failed: \(String(describing: error))"
            )
            onDiscardLiveEdits?()
        }
    }

    // MARK: - Pencil interpretation application (tasks 3.3/3.4: the grammar)

    /// Wall-clock double-tap window and normalized-viewport tap radius.
    static let doubleTapWindow: TimeInterval = 0.5
    static let doubleTapRadius: Float = 0.06
    /// A visibility line must be decisively vertical: |dy| > slope * |dx|.
    static let visibilityLineSlope: Float = 2

    /// Last single tap that resolved to a vertex (double-tap detection).
    private var lastVertexTap: (time: TimeInterval, position: SIMD2<Float>, vertex: UInt32)?

    /// Applies the best candidate through the grammar and reports how the
    /// stroke resolved (task 3.5 chip). When a command committed AND the
    /// pre-stroke snapshot supports rebuilding alternatives, the swap
    /// context is captured for `applyAlternative(at:)`.
    private func applyPencilInterpretation(
        _ interpretation: StrokeInterpretation?, samples: [StrokeSample]
    ) -> PencilStrokeOutcome {
        lastCommit = nil
        lastApplied = nil
        guard let interpretation, let best = interpretation.best,
            let context = contextProvider?()
        else {
            return PencilStrokeOutcome(
                interpretation: interpretation, appliedIndex: nil, alternatives: []
            )
        }
        applyBestCandidate(best, of: interpretation, samples: samples, context: context)
        guard let command = lastCommit else {
            return PencilStrokeOutcome(
                interpretation: interpretation, appliedIndex: nil, alternatives: []
            )
        }
        // Swap context: only strokes that edited an EXISTING EditMesh are
        // swappable (the first-stroke `addObject` path has no pre-stroke
        // payload to rebuild alternatives from — its chip is informational).
        if let object = context.editObject, let payload = context.editPayload {
            var corners: [SIMD3<Float>]?
            if interpretation.candidates.contains(where: { $0.action == .createQuad }),
                interpretation.quadCorners.count == 4 {
                corners = unprojectCorners(interpretation.quadCorners, in: context)
            }
            lastApplied = AppliedPencilStroke(
                interpretation: interpretation,
                appliedIndex: 0,
                command: command,
                object: object,
                beforePayload: payload,
                beforeAnnotations: object.annotations,
                worldCorners: corners
            )
        }
        return PencilStrokeOutcome(
            interpretation: interpretation,
            appliedIndex: 0,
            alternatives: lastApplied.map(swappableAlternatives(for:)) ?? []
        )
    }

    private func applyBestCandidate(
        _ best: StrokeInterpretation.Candidate, of interpretation: StrokeInterpretation,
        samples: [StrokeSample], context: Context
    ) {
        switch best.action {
        case .createQuad:
            guard interpretation.quadCorners.count == 4 else { return }
            applyCreate(
                verb: "pencil.createQuad",
                screenPoints: interpretation.quadCorners,
                context: context
            ) { mesh, corners, snapper in
                try mesh.createFace(at: corners, snapping: snapper)
            }
        case .createGrid:
            guard let grid = interpretation.gridSize,
                interpretation.quadCorners.count == (grid.rows + 1) * (grid.cols + 1)
            else { return }
            // The whole block lands as ONE welded engine grid in ONE
            // journal entry per grid stroke.
            applyCreate(
                verb: "pencil.createGrid",
                screenPoints: interpretation.quadCorners,
                context: context
            ) { mesh, lattice, snapper in
                try mesh.createGrid(
                    lattice: lattice, rows: grid.rows, cols: grid.cols, snapping: snapper
                )
            }
        case .insertLoop:
            let ring = elementIDs(of: best, kind: .edge)
            guard let seed = ring.first else { return }
            applyElementEdit(verb: "pencil.insertLoop", context: context) { mesh in
                try mesh.insertLoop(acrossEdge: seed)
            }
        case .dissolveEdge:
            let edges = elementIDs(of: best, kind: .edge)
            guard !edges.isEmpty else { return }
            applyElementEdit(verb: "pencil.dissolveEdge", context: context) { mesh in
                try mesh.dissolveEdges(edges)
            }
        case .deleteFaces:
            let faces = elementIDs(of: best, kind: .face)
            guard !faces.isEmpty else { return }
            applyElementEdit(verb: "pencil.deleteFaces", context: context) { mesh in
                try mesh.deleteFaces(faces)
            }
        case .mergeVertices:
            // The stroke's start vertex snaps onto its end vertex.
            let vertices = elementIDs(of: best, kind: .vertex)
            guard vertices.count == 2 else { return }
            applyElementEdit(verb: "pencil.mergeVertices", context: context) { mesh in
                try mesh.mergeVertices(keep: vertices[1], remove: vertices[0])
            }
        case .rotateEdge:
            guard let edge = elementIDs(of: best, kind: .edge).first else { return }
            applyElementEdit(verb: "pencil.rotateEdge", context: context) { mesh in
                try mesh.rotateEdge(edge)
            }
        case .tagLoop:
            let loop = elementIDs(of: best, kind: .edge)
            guard !loop.isEmpty else { return }
            applyAnnotationEdit(verb: "pencil.tagLoop", context: context) { annotations in
                annotations.togglingTags(on: loop)
            }
        case .hideRegion:
            let faces = elementIDs(of: best, kind: .face)
            guard !faces.isEmpty else { return }
            applyAnnotationEdit(verb: "pencil.hideRegion", context: context) { annotations in
                annotations.hiding(faces: faces)
            }
        case .toggleVisibility:
            applyVisibilityLine(samples: samples, context: context)
        case .tweakVertex:
            registerVertexTap(best, samples: samples)
        case .none:
            break
        }
    }

    private func elementIDs(
        of candidate: StrokeInterpretation.Candidate,
        kind: StrokeInterpretation.Element.Kind
    ) -> [UInt32] {
        candidate.elements.filter { $0.kind == kind }.map(\.id)
    }

    // MARK: - One-tap alternative swap (task 3.5, spec: pencil-interaction /
    // "One-tap misrecognition fix")

    /// Swaps the last applied Pencil result for the ranked alternative at
    /// candidate `index`: the replacement command is rebuilt from the
    /// PRE-stroke snapshot and handed to `onReplaceCommit`, which reverts
    /// the applied command, applies the replacement, and replaces the
    /// journal entry in place — exactly ONE journal entry after the swap,
    /// no extra undo step. Returns the refreshed outcome (the chip re-shows
    /// with the swapped result and the remaining alternatives, so the user
    /// can swap back), or nil when the swap was not possible (stale chip,
    /// unbuildable candidate, no-op replacement).
    @discardableResult
    func applyAlternative(at index: Int) -> PencilStrokeOutcome? {
        guard var stroke = lastApplied,
            index != stroke.appliedIndex,
            let candidate = stroke.interpretation.candidates[safe: index],
            canBuildReplacement(candidate, stroke: stroke)
        else { return nil }
        let replacement: DocumentCommand?
        do {
            replacement = try replacementCommand(for: candidate, stroke: stroke)
        } catch {
            Self.log.error(
                "alternative swap (\(candidate.action.rawValue)) failed: \(String(describing: error))"
            )
            lastApplied = nil
            return nil
        }
        guard let replacement,
            onReplaceCommit?(replacement, stroke.command) == true
        else {
            // Either the alternative is a no-op on the pre-stroke state or
            // the journal moved on (undo tap / later commit): the chip is
            // stale, drop the swap context.
            lastApplied = nil
            return nil
        }
        stroke.command = replacement
        stroke.appliedIndex = index
        lastApplied = stroke
        return PencilStrokeOutcome(
            interpretation: stroke.interpretation,
            appliedIndex: index,
            alternatives: swappableAlternatives(for: stroke)
        )
    }

    /// Candidate indices the chip may offer as one-tap swaps: every ranked
    /// candidate other than the applied one whose replacement command can
    /// be rebuilt deterministically from the captured pre-stroke snapshot.
    private func swappableAlternatives(for stroke: AppliedPencilStroke) -> [Int] {
        stroke.interpretation.candidates.indices.filter { index in
            index != stroke.appliedIndex
                && canBuildReplacement(
                    stroke.interpretation.candidates[index], stroke: stroke
                )
        }
    }

    private func canBuildReplacement(
        _ candidate: StrokeInterpretation.Candidate, stroke: AppliedPencilStroke
    ) -> Bool {
        switch candidate.action {
        case .insertLoop, .tagLoop, .dissolveEdge, .rotateEdge:
            return !elementIDs(of: candidate, kind: .edge).isEmpty
        case .deleteFaces, .hideRegion:
            return !elementIDs(of: candidate, kind: .face).isEmpty
        case .mergeVertices:
            return elementIDs(of: candidate, kind: .vertex).count == 2
        case .createQuad:
            return stroke.worldCorners?.count == 4
        case .none, .toggleVisibility, .tweakVertex, .createGrid:
            // Not swappable: no journal-entry equivalent (verb switch /
            // direction-dependent visibility) or no captured lattice.
            return false
        }
    }

    /// Builds the journal-ready replacement for `candidate` against the
    /// pre-stroke snapshot. Returns nil when the alternative is a no-op.
    private func replacementCommand(
        for candidate: StrokeInterpretation.Candidate, stroke: AppliedPencilStroke
    ) throws -> DocumentCommand? {
        switch candidate.action {
        case .tagLoop:
            return annotationReplacement(verb: "pencil.tagLoop", stroke: stroke) {
                $0.togglingTags(on: elementIDs(of: candidate, kind: .edge))
            }
        case .hideRegion:
            return annotationReplacement(verb: "pencil.hideRegion", stroke: stroke) {
                $0.hiding(faces: elementIDs(of: candidate, kind: .face))
            }
        default:
            return try meshReplacement(for: candidate, stroke: stroke)
        }
    }

    private func annotationReplacement(
        verb: String, stroke: AppliedPencilStroke,
        _ transform: (MeshAnnotations) -> MeshAnnotations
    ) -> DocumentCommand? {
        let before = stroke.beforeAnnotations
        let transformed = transform(before ?? MeshAnnotations())
        let after: MeshAnnotations? = transformed.isEmpty ? nil : transformed
        guard after != before else { return nil }
        return .annotationEdit(DocumentCommand.AnnotationEdit(
            objectID: stroke.object.id, verb: verb, before: before, after: after
        ))
    }

    /// Topology alternatives run on a SCRATCH mesh deserialized from the
    /// pre-stroke payload (candidate element ids reference that topology);
    /// the live mesh is left alone — the document swap re-syncs it through
    /// the normal payload-changed path.
    private func meshReplacement(
        for candidate: StrokeInterpretation.Candidate, stroke: AppliedPencilStroke
    ) throws -> DocumentCommand? {
        let mesh = try Mesh(payloadData: stroke.beforePayload)
        let transaction = MeshEditTransaction(
            object: stroke.object, mesh: mesh, currentPayload: stroke.beforePayload
        )
        let verb: String
        switch candidate.action {
        case .insertLoop:
            guard let seed = elementIDs(of: candidate, kind: .edge).first else { return nil }
            try mesh.insertLoop(acrossEdge: seed)
            verb = "pencil.insertLoop"
        case .dissolveEdge:
            try mesh.dissolveEdges(elementIDs(of: candidate, kind: .edge))
            verb = "pencil.dissolveEdge"
        case .deleteFaces:
            try mesh.deleteFaces(elementIDs(of: candidate, kind: .face))
            verb = "pencil.deleteFaces"
        case .mergeVertices:
            let vertices = elementIDs(of: candidate, kind: .vertex)
            guard vertices.count == 2 else { return nil }
            try mesh.mergeVertices(keep: vertices[1], remove: vertices[0])
            verb = "pencil.mergeVertices"
        case .rotateEdge:
            guard let edge = elementIDs(of: candidate, kind: .edge).first else { return nil }
            try mesh.rotateEdge(edge)
            verb = "pencil.rotateEdge"
        case .createQuad:
            guard let corners = stroke.worldCorners, corners.count == 4 else { return nil }
            try mesh.createFace(at: corners, snapping: contextProvider?()?.snapper)
            verb = "pencil.createQuad"
        default:
            return nil
        }
        return try transaction.command(verb: verb)
    }

    // MARK: Element edits (journaled mutations of existing topology)

    /// The journaled epilogue for grammar entries that mutate EXISTING
    /// elements (insert loop, dissolve, delete, merge, rotate): unlike the
    /// surface-anchored create/brush verbs these need no Target. Everything
    /// from the first mutation to the journal entry runs inside
    /// `journalOrDiscard` (see that method for the failure contract).
    /// Internal (not private): the task-4.1 tool extension reuses it.
    func applyElementEdit(
        verb: String, context: Context, _ mutate: @escaping (Mesh) throws -> Void
    ) {
        guard
            let object = context.editObject,
            let mesh = context.editMesh,
            let payload = context.editPayload
        else { return }
        let transaction = MeshEditTransaction(
            object: object, mesh: mesh, currentPayload: payload
        )
        journalOrDiscard(verb: verb) {
            try mutate(mesh)
            onLiveEdit?()
            return try transaction.command(verb: verb)
        }
    }

    // MARK: Annotation edits (loop tags + visibility, task 3.4)

    /// Journals an annotation change as ONE `annotationEdit` command.
    /// Annotations are manifest state — payload bytes never move, and a
    /// no-op transform journals nothing.
    private func applyAnnotationEdit(
        verb: String, context: Context,
        _ transform: (MeshAnnotations) -> MeshAnnotations
    ) {
        guard let object = context.editObject else { return }
        let before = object.annotations
        let transformed = transform(before ?? MeshAnnotations())
        let after: MeshAnnotations? = transformed.isEmpty ? nil : transformed
        guard after != before else { return }
        send(.annotationEdit(DocumentCommand.AnnotationEdit(
            objectID: object.id, verb: verb, before: before, after: after
        )))
    }

    /// Straight line in empty space: decisively downward inverts
    /// visibility, upward shows all (spec grammar table). Anything not
    /// clearly vertical (the recognizer cannot see direction) is inert.
    private func applyVisibilityLine(samples: [StrokeSample], context: Context) {
        guard let first = samples.first, let last = samples.last else { return }
        let dx = Float(last.x - first.x)
        let dy = Float(last.y - first.y)
        guard abs(dy) > Self.visibilityLineSlope * abs(dx) else { return }
        if dy > 0 {
            // Downward: invert against the full live-face set.
            guard let mesh = context.editMesh else { return }
            let allFaces = mesh.liveFaceIDs()
            guard !allFaces.isEmpty else { return }
            applyAnnotationEdit(verb: "pencil.invertVisibility", context: context) {
                $0.invertingVisibility(allFaces: allFaces)
            }
        } else {
            applyAnnotationEdit(verb: "pencil.showAll", context: context) {
                $0.showingAll()
            }
        }
    }

    // MARK: Double-tap → Tweak (task 3.4)

    /// A hold/tap that resolved to a vertex: a second tap on the same
    /// vertex within the double-tap window activates the Tweak verb
    /// (CozyBlanket: double-tap with the Pencil switches to Tweak; the
    /// following drag moves the vertex). Double-tap on an edge (slide the
    /// loop) needs the engine loop-slide op — deferred, see tasks.md 3.4a.
    private func registerVertexTap(
        _ candidate: StrokeInterpretation.Candidate, samples: [StrokeSample]
    ) {
        guard let vertex = elementIDs(of: candidate, kind: .vertex).first,
            let first = samples.first
        else { return }
        let position = SIMD2(Float(first.x), Float(first.y))
        let now = ProcessInfo.processInfo.systemUptime
        if let previous = lastVertexTap,
            previous.vertex == vertex,
            now - previous.time <= Self.doubleTapWindow,
            simd_distance(previous.position, position) <= Self.doubleTapRadius {
            // Fired: consume BOTH taps so a triple-tap cannot re-fire off
            // the second one.
            lastVertexTap = nil
            onRequestVerb?(.tweak)
            return
        }
        lastVertexTap = (now, position, vertex)
    }

    // MARK: Face creation (quad draw + one-stroke grid)

    /// Creates geometry over screen-space points unprojected onto the
    /// Target: `build` runs the engine creation op (a quad's `createFace`,
    /// the grid's welded `createGrid`) against the destination mesh with
    /// the unprojected world points.
    private func applyCreate(
        verb: String, screenPoints: [SIMD2<Float>], context: Context,
        _ build: @escaping (Mesh, [SIMD3<Float>], SurfaceSnapper?) throws -> Void
    ) {
        guard
            context.snapper != nil,
            let points = unprojectCorners(screenPoints, in: context)
        else { return }
        if let object = context.editObject, let mesh = context.editMesh,
            let payload = context.editPayload {
            // LIVE mesh path: everything from the first mutation to the
            // journal entry runs inside `journalOrDiscard`, so ANY failure
            // after the mesh may have changed (a partial-mutation engine
            // error inside `build`, or serialization failing in
            // `command(verb:)` AFTER geometry landed and `onLiveEdit`
            // fired) discards the live edits instead of leaving the
            // overlay permanently diverged from the document with no
            // journal entry. A degenerate-ring/lattice rejection leaves
            // the mesh untouched (engine contract), so its discard reloads
            // identical state — harmless.
            let transaction = MeshEditTransaction(
                object: object, mesh: mesh, currentPayload: payload
            )
            journalOrDiscard(verb: verb) {
                try build(mesh, points, context.snapper)
                onLiveEdit?()
                return try transaction.command(verb: verb)
            }
        } else if !context.documentHasEditMesh {
            // First stroke of a retopo: creates the EditMesh object itself
            // (undo removes the whole object — exact by construction). The
            // mesh here is LOCAL — a failure leaves no live state behind,
            // so plain logging is enough.
            do {
                let mesh = try Mesh()
                try build(mesh, points, context.snapper)
                let id = UUID()
                let object = DocumentManifest.Object(
                    id: id,
                    name: "EditMesh",
                    role: .editMesh,
                    payloadFile: "\(id.uuidString).payload",
                    counts: .init(vertices: mesh.vertexCount, faces: mesh.faceCount)
                )
                send(.addObject(object: object, payload: try mesh.payloadData()))
            } catch {
                Self.log.error("\(verb) failed: \(String(describing: error))")
            }
        } else {
            // The document HAS an EditMesh but the viewport snapshot is
            // unusable (payload failed to deserialize). Creating a
            // second `.editMesh` object here would leave an invisible,
            // uneditable duplicate in the manifest and journal — drop
            // the stroke instead.
            Self.log.error(
                "\(verb) skipped: EditMesh snapshot unusable (corrupt payload?)"
            )
        }
    }

    /// Unprojects the recognizer's screen-space corner estimates onto the
    /// Target: raycast first; a grazing miss falls back to the closest
    /// surface point of the ray point at the median hit depth. Returns nil
    /// unless all four corners land.
    private func unprojectCorners(
        _ corners: [SIMD2<Float>], in context: Context
    ) -> [SIMD3<Float>]? {
        guard let snapper = context.snapper else { return nil }
        var rays: [Ray] = []
        var hits: [SIMD3<Float>?] = []
        var hitDistances: [Float] = []
        for corner in corners {
            guard let ray = context.ray(corner) else { return nil }
            rays.append(ray)
            if let hit = snapper.raycast(origin: ray.origin, direction: ray.direction) {
                hits.append(hit.point)
                hitDistances.append(hit.distance)
            } else {
                hits.append(nil)
            }
        }
        guard !hitDistances.isEmpty else { return nil }
        let median = hitDistances.sorted()[hitDistances.count / 2]
        var result: [SIMD3<Float>] = []
        for (index, hit) in hits.enumerated() {
            if let hit {
                result.append(hit)
            } else {
                let probe = rays[index].origin + rays[index].direction * median
                guard let snapped = snapper.snapToSurface(probe) else { return nil }
                result.append(snapped.point)
            }
        }
        return result
    }

    // MARK: - Visual-verification probe (task 3.7 screenshot hook)

    /// Begins a REAL Tweak session dragging one EditMesh vertex within
    /// merge range of another and leaves the stroke IN FLIGHT, so the
    /// snap-target pre-highlight is visible for a screenshot (the
    /// simulator cannot synthesize a Pencil drag; this drives the exact
    /// stroke entry points the capture pipeline uses). Scans a coarse
    /// viewport lattice for a grab point (a vertex within pick radius)
    /// and a drop point whose surface hit lies within merge range of a
    /// DIFFERENT vertex. Returns whether a highlight engaged.
    @discardableResult
    func probeSnapHighlightForVisualVerification() -> Bool {
        guard let context = contextProvider?(), let mesh = context.editMesh
        else { return false }
        let mergeRadius = context.sceneRadius * Self.mergeSnapRadiusFraction
        let pickRadius = context.sceneRadius * Self.vertexPickRadiusFraction
        let steps = 48
        var grabs: [(point: SIMD2<Float>, vertex: UInt32)] = []
        var drops: [(point: SIMD2<Float>, vertex: UInt32)] = []
        for row in 0...steps {
            for col in 0...steps {
                let point = SIMD2(Float(col) / Float(steps), Float(row) / Float(steps))
                guard let hit = surfacePoint(at: point, in: context) else { continue }
                if let pick = mesh.nearestVertex(to: hit, maxDistance: mergeRadius * 0.9) {
                    drops.append((point, pick.vertex))
                } else if let pick = mesh.nearestVertex(to: hit, maxDistance: pickRadius) {
                    grabs.append((point, pick.vertex))
                }
            }
        }
        for grab in grabs {
            guard let drop = drops.first(where: { $0.vertex != grab.vertex })
            else { continue }
            strokeBegan(verb: .tweak, sample: probeSample(at: grab.point, time: 0))
            strokeContinued(sample: probeSample(at: drop.point, time: 0.05))
            if snapFeedback.candidate != nil {
                return true  // stroke stays in flight: highlight on screen
            }
            strokeCancelled()
        }
        return false
    }

    func probeSample(at point: SIMD2<Float>, time: TimeInterval) -> StrokeSample {
        StrokeSample(
            time: time, x: Double(point.x), y: Double(point.y),
            pressure: 0.5, type: .pencil
        )
    }

    // MARK: - Geometry helpers
    // Internal (not private): the task-4.1 tool extension
    // (MeshEditToolSession.swift) shares them.

    func point(of sample: StrokeSample) -> SIMD2<Float> {
        SIMD2(Float(sample.x), Float(sample.y))
    }

    /// Where the sample's camera ray meets the Target surface.
    func surfacePoint(
        at point: SIMD2<Float>, in context: Context
    ) -> SIMD3<Float>? {
        guard let snapper = context.snapper, let ray = context.ray(point) else { return nil }
        return snapper.raycast(origin: ray.origin, direction: ray.direction)?.point
    }
}

/// Pure camera-unprojection math (shell-owned camera geometry, design D1;
/// separated for headless unit testing).
enum ScreenRay {
    /// World-space ray through a normalized viewport point (0...1, origin
    /// top-left), from the inverse of the column-major world→clip matrix
    /// (Metal NDC: z in [0, 1]).
    static func ray(
        inverseViewProjection inverse: simd_float4x4, normalizedPoint point: SIMD2<Float>
    ) -> MeshEditController.Ray? {
        let ndcX = point.x * 2 - 1
        let ndcY = 1 - point.y * 2
        let near4 = inverse * SIMD4(ndcX, ndcY, 0, 1)
        let far4 = inverse * SIMD4(ndcX, ndcY, 1, 1)
        guard abs(near4.w) > .ulpOfOne, abs(far4.w) > .ulpOfOne else { return nil }
        let near = SIMD3(near4.x, near4.y, near4.z) / near4.w
        let far = SIMD3(far4.x, far4.y, far4.z) / far4.w
        let direction = far - near
        let length = simd_length(direction)
        guard length.isFinite, length > 0 else { return nil }
        return (near, direction / length)
    }

    /// Normalized viewport point of a world position under the column-major
    /// world→clip matrix (the forward direction of `ray`; Metal NDC).
    /// Returns nil for points at/behind the camera plane (w <= 0).
    static func normalizedPoint(
        of world: SIMD3<Float>, viewProjectionColumns m: [Float]
    ) -> SIMD2<Float>? {
        guard m.count == 16 else { return nil }
        let cx = m[0] * world.x + m[4] * world.y + m[8] * world.z + m[12]
        let cy = m[1] * world.x + m[5] * world.y + m[9] * world.z + m[13]
        let cw = m[3] * world.x + m[7] * world.y + m[11] * world.z + m[15]
        guard cw > .ulpOfOne else { return nil }
        let x = cx / cw * 0.5 + 0.5
        let y = 1 - (cy / cw * 0.5 + 0.5)
        guard x.isFinite, y.isFinite else { return nil }
        return SIMD2(x, y)
    }
}

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
        /// `editObject`'s annotation state (task 4.3): loop tags, hidden
        /// faces and PINS. The brush verbs read `pinnedVertices` out of it
        /// and hand it to the engine on every Relax/Move call, which is
        /// what makes pins immune to smoothing (spec: retopology-tools /
        /// "Pins immune to smoothing"); the annotation edits journal
        /// against it.
        var annotations: MeshAnnotations?
        /// The document's current stage (6.2b). Read by the grammar, because the SAME stroke
        /// shape means different things per stage: an X deletes faces in retopology and
        /// re-unwraps an island in UV. Optional so a headless context that never set one is
        /// distinguishable from one that chose a stage — and an unset stage must behave as
        /// "not retopology", since defaulting to `.retopology` would make every context that
        /// forgot to set it silently destructive.
        var stage: DocumentManifest.Stage?
        /// Document symmetry state (task 4.4): which mirror axes and how
        /// many radial sectors authoring replicates under, and where the
        /// symmetry origin sits. Read fresh at stroke begin like
        /// everything else here, so toggling symmetry takes effect on the
        /// very next stroke.
        /// nil = the document has never set symmetry (pre-4.4 documents),
        /// which is why this is optional rather than a resolved value:
        /// journaling `setSymmetry` has to be able to revert BACK to
        /// "never set" so undo leaves the manifest byte-identical.
        var symmetry: SymmetrySettings?
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
        /// The arbiter's camera→tool gate right now
        /// (`InputArbiter.cameraFeedsArmedTool`): true when camera motion
        /// is allowed to steer the armed camera-tool session.
        ///
        /// The commit path reads this before refreshing the session from
        /// the live camera. With the gate CLOSED (a pen-down /
        /// palm-rejected touch moved the renderer camera but was
        /// deliberately withheld from the session) the ghost preview never
        /// moved, so committing against that stray pose would paste the
        /// patch somewhere other than where the user saw it. Defaults to
        /// true so headless tests, which drive `cameraPoseChanged`
        /// directly, keep the plain re-read behaviour.
        var cameraFeedsArmedTool = true
        /// Orbits the LIVE viewport camera by screen points (task 4.2
        /// probes: the camera-tool screenshot hooks must move the real
        /// camera the session and the frame both read; nil headless).
        var orbitCamera: ((SIMD2<Float>) -> Void)? = nil

        /// Symmetry state with the pre-4.4 default (symmetry off) filled
        /// in — what every consumer of symmetry should read.
        var effectiveSymmetry: SymmetrySettings { symmetry ?? SymmetrySettings() }
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
    /// The pending seam proposal changed (task 6.5). Separate from `onLiveEdit` because a
    /// proposal is NOT a mutation: nothing is journaled and no geometry moved, so it must not
    /// go through the live-edit refresh that re-uploads the mesh. Its only effect is that the
    /// amber overlay redraws.
    var onSeamProposalChanged: (([UInt32]) -> Void)?
    /// Reads a sidecar file from the document (6.7a). Needed because a UV-set command has to pin
    /// the BEFORE bytes for byte-exact revert, and the controller has no document access of its
    /// own — the same shape as `contextProvider` supplying the payload.
    var onReadSidecar: ((String) -> Data?)?
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
    /// Which scope a live Move drag picked up — "Vertex" / "Loop" / "Surface",
    /// nil when no Move drag is live (openspec add-context-aware-move; spec:
    /// pencil-interaction / "The viewport names the scope before the drag
    /// commits").
    ///
    /// The scope turns on a distance as small as a third of a cell. If it were
    /// knowable only from the result, a mis-pick would be discovered after the
    /// mesh had already changed.
    var onMoveScopeChanged: ((String?) -> Void)?
    /// The painted Target region changed (openspec add-painted-region-retopo):
    /// the viewport draws the extent so it is visible before a solve runs. Empty
    /// clears it.
    var onPaintedRegionChanged: (([UInt32]) -> Void)?

    /// Target faces painted for the next region solve. Viewport state: never
    /// journaled, never persisted, cleared when a solve runs.
    var paintedRegion = PaintedRegion()
    /// Injected haptic seam (task 3.7): nil = silent. Tests inject a
    /// recording fake; the coordinator installs the capability-gated
    /// `SnapHapticsEngine` (graceful no-op on simulator).
    var haptics: SnapHapticsPlaying?
    /// Palette index new loop tags are authored in (task 4.3, spec:
    /// "Users SHALL color-tag edge loops"). Mirrored from the editor's
    /// palette control; re-tagging a loop in a DIFFERENT colour recolours
    /// it, re-tagging in the SAME colour clears it.
    var activeTagColor: UInt8 = MeshAnnotations.defaultTagColor
    /// Backing storage for the UV unwrap's report and refusal (task 6.1). Here rather than
    /// in `MeshEditUV.swift` only because a Swift extension cannot add stored properties;
    /// the behaviour lives with the action.
    var unwrapReportStorage: Mesh.AtlasReport?
    var unwrapRefusalStorage: String?
    /// Pending auto-seam proposal (task 6.5). Storage lives here only because a Swift
    /// extension cannot add stored properties; the behaviour is in `MeshEditUV.swift`.
    var seamProposalStorage: [UInt32] = []
    var seamProposalNoticeStorage: String?
    /// Loop Info sink (task 4.3, spec: "Loop Info inspection"): fired when
    /// the hovered interior edge's loop metrics change; nil clears the
    /// chip.
    var onLoopInfoChanged: ((LoopInfoChipState.Info?) -> Void)?
    /// Auto Relax mode (task 4.5, spec: retopology-tools / "Auto Relax").
    /// While on, a participating editing operation also relaxes the
    /// neighborhood it touched — INSIDE the operation's own transaction, so
    /// the user gets ONE undo step per action. Mirrored from the persisted
    /// `ViewportSettings.autoRelaxKey` setting through `ViewportInputModel`.
    ///
    /// **NOT every operation participates** (task 4.5a, and the HONEST
    /// SCOPE block in tests/traceability.yaml says the same). Participating:
    /// the create paths (`applyCreate`), the element-edit GRAMMAR entries
    /// (insert loop, dissolve, merge, rotate — they pass `autoRelaxAround:`)
    /// and the Build Quad / Build Triangle drags. NOT participating: the
    /// camera-as-manipulator tools, Surface Cut, Draw Strip, Path
    /// Distribute, the Merge Pair TOOL (it calls `applyElementEdit` with the
    /// default empty `autoRelaxAround`, which disables the pass) and the
    /// brush verbs Move / Tweak / Erase (`commit` journals without it). A
    /// pass needs a defensible neighbourhood per tool, which is a per-tool
    /// decision, not one switch — so the scope is stated rather than
    /// implied.
    var autoRelaxEnabled = false

    // Brush sizing as fractions of the scene radius. Values chosen for the
    // CozyBlanket-like feel at typical cage density; user-facing brush size
    // controls arrive with the full toolbar (task 3.8).
    static let relaxRadiusFraction: Float = 0.18
    static let moveRadiusFraction: Float = 0.3
    static let eraseBaseRadiusFraction: Float = 0.08
    nonisolated static let vertexPickRadiusFraction: Float = 0.12
    /// Draw Strip release-merge cap (task 4.2a): a rail vertex may weld onto
    /// existing topology no further than this fraction of the strip's own
    /// width, so it can never reach across the strip to its opposite rail.
    static let stripWeldWidthFraction: Float = 0.35
    static let relaxStrength: Float = 0.35
    /// Merge-snap range (task 3.7): how close the DRAGGED vertex must come
    /// to another vertex for the snap target to pre-highlight and the
    /// stroke-end merge/snap to engage. Deliberately much tighter than the
    /// grab radius so ordinary tweaks near neighbors do not merge.
    nonisolated static let mergeSnapRadiusFraction: Float = 0.04

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

    /// What a Move drag carries, decided from the element under its FIRST
    /// sample (openspec add-context-aware-move; spec: pencil-interaction /
    /// "Move's scope is what the drag starts on").
    ///
    /// Resolved ONCE, at grab, and held for the whole drag: the gesture must not
    /// change meaning under the finger, and a drag journals ONE entry — one that
    /// would otherwise end up describing something the artist never started.
    enum MoveScope: Equatable {
        /// Started on a vertex: that vertex alone, no falloff.
        case vertex(UInt32)
        /// Started on an edge: its whole loop, rigidly. `edge` is the edge the
        /// pick landed on — the hover preview walks it to draw the loop, so that
        /// the highlight and the drag can never disagree about which loop it is
        /// (openspec add-hover-scope-highlight, design D2). `seed` is the vertex
        /// the pick measured from, kept for diagnostics.
        case loop([UInt32], edge: UInt32, seed: UInt32)
        /// Started on a face: today's geodesic falloff around `seed`.
        case surface(seed: UInt32)

        /// Name shown while the drag is live, so what it grabbed is knowable
        /// before it commits.
        var hint: String {
            switch self {
            case .vertex: return "Vertex"
            case .loop: return "Loop"
            case .surface: return "Surface"
            }
        }

        /// Journal suffix. Surface keeps the bare `move` verb so existing
        /// history and tests keep their meaning.
        var verbSuffix: String {
            switch self {
            case .vertex: return ".vertex"
            case .loop: return ".loop"
            case .surface: return ""
            }
        }

        /// Only a single-target drag may merge on release: a loop release would
        /// decide a merge for every vertex at once, from a gesture that shows
        /// only where the loop landed.
        var mergesOnRelease: Bool {
            if case .loop = self { return false }
            return true
        }
    }

    private struct Session {
        var verb: InputArbiter.Verb
        var context: Context
        var transaction: MeshEditTransaction
        /// Vertex grabbed at stroke start (Move seed / Tweak target).
        var grabbedVertex: UInt32?
        /// What a Move drag carries. Nil for every other verb.
        var moveScope: MoveScope?
        /// Last surface point of the drag (Move displacement anchor).
        var anchor: SIMD3<Float>?
        /// Merge range for THIS drag, measured from the grabbed vertex's own
        /// cell at grab time (see `mergeRange`). Held on the session because
        /// it is a per-drag constant and the scan behind it is O(edges).
        var mergeRange: Float = 0
        var mutated = false
    }

    private var session: Session?

    /// True while a session holds live (not yet journaled) mesh state a
    /// document resync would clobber: a brush-verb scrub, or a Transform
    /// Vertices camera session (task 4.2 — its camera feed mutates the
    /// live mesh ahead of the journal exactly like a brush drag).
    var isSessionActive: Bool { session != nil || cameraSessionHoldsLiveMesh }

    /// Status line shown when a whole-mesh command is refused because a
    /// session still holds uncommitted live edits.
    static let liveEditsBlockWholeMeshCommand =
        "Finish or cancel the active tool before running a whole-mesh command"

    /// Whether a WHOLE-MESH command (a batch command, a symmetry bake) may
    /// run right now.
    ///
    /// These commands take `context.editMesh` — the LIVE handle — and pin
    /// `context.editPayload` as the transaction's `before`. While a session
    /// is active those two disagree: an armed Transform Vertices session
    /// has already mutated the handle in place (`applyTransformSessionDelta`)
    /// while the payload is still the pre-session bytes, and a brush scrub
    /// does the same. Running anyway would journal the session's
    /// uncommitted mutation inside the whole-mesh command's entry, and the
    /// snapshot rebind that follows reaches `editMeshSnapshotWillChange`
    /// with `expectingOwnCommit == false`, dropping the session WITHOUT
    /// `onDiscardLiveEdits` — the user's unconfirmed placement is committed
    /// permanently under someone else's undo entry.
    ///
    /// So: refuse, and tell the user to commit or cancel first.
    func allowsWholeMeshCommand(reporting: Bool = true) -> Bool {
        guard isSessionActive else { return true }
        if reporting { onCameraToolStatus?(Self.liveEditsBlockWholeMeshCommand) }
        return false
    }

    /// Status line shown when a NEW stroke is refused because a camera-as-
    /// manipulator session still holds uncommitted live mesh edits.
    static let liveEditsBlockStroke =
        "Finish or cancel the active tool session before editing"

    /// Whether a new stroke may pin the document snapshot right now.
    ///
    /// This is `allowsWholeMeshCommand`'s reasoning applied to strokes, and
    /// it is needed for exactly the same reason: an armed Transform
    /// Vertices session has already mutated `context.editMesh` in place
    /// (`applyTransformSessionDelta`) while `context.editPayload` is still
    /// the PRE-session bytes, and `resyncFromDocumentIfIdle()` is
    /// suppressed while it holds them. A brush scrub or a build-tool stroke
    /// started on top would pin those stale bytes as its transaction's
    /// `before` and journal an entry whose `after` bakes in the user's
    /// unconfirmed placement — and the session, still armed with its own
    /// transaction pinned to the same bytes, would later commit a `before`
    /// that wipes the stroke back out again.
    ///
    /// Spring-loaded verb holds are the way in: `verbPressBegan` does NOT
    /// disarm the tool (only a persistent tap does), so a held Relax can
    /// reach `strokeBegan` with the session still armed.
    ///
    /// The camera tools' OWN strokes are exempt — (re)selecting and
    /// tap-to-commit are how the session is driven, and both paths refresh
    /// the snapshot themselves (see `handleCameraToolStroke`).
    private func allowsStrokeAgainstLiveMesh() -> Bool {
        guard cameraSessionHoldsLiveMesh else { return true }
        onCameraToolStatus?(Self.liveEditsBlockStroke)
        return false
    }

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

    /// Authored guide strokes (add-guide-stroke-authoring): world-space
    /// polylines on the Target that steer the next Auto-Retopo's edge flow.
    /// Session state — not journaled, not persisted. The Guide tool appends
    /// here on stroke end; the viewport renders them and Auto-Retopo consumes
    /// them.
    private(set) var authoredGuides: [[SIMD3<Float>]] = []
    /// Fired whenever `authoredGuides` changes, so the coordinator can refresh
    /// the guide-line overlay.
    var onGuidesChanged: (() -> Void)?

    /// Removes every authored guide.
    func clearGuides() {
        guard !authoredGuides.isEmpty else { return }
        authoredGuides.removeAll()
        onGuidesChanged?()
    }

    /// Appends a captured world-space guide polyline (empty polylines — a
    /// stroke that missed the Target — are ignored).
    func appendGuide(_ polyline: [SIMD3<Float>]) {
        guard polyline.count >= 2 else { return }
        authoredGuides.append(polyline)
        onGuidesChanged?()
    }

    // MARK: - Camera-as-manipulator sessions (task 4.2)

    /// Active camera-as-manipulator session (Patch Clone / Extend
    /// Boundary / Transform Vertices): a selection stroke arms it, camera
    /// deltas drive it (routed through the InputArbiter), commit journals
    /// ONCE, cancel discards. See `MeshEditCameraTools.swift`.
    var cameraSession: CameraToolSession?
    /// Pending Weave Fill request (add-weave-region-selection). NOT document state
    /// and not persisted — an unexecuted intent, cleared with the proposal it feeds.
    var weaveFillIntent: WeaveFillIntent?
    /// Fires whenever the pending request changes, so the shell can re-solve and
    /// refresh the banner.
    var onWeaveFillIntentChanged: ((WeaveFillIntent?) -> Void)?
    /// Accepts a pending Weave Fill proposal. Installed by the shell (the proposal
    /// slot lives on the Coordinator); used by the visual-verification probe so it
    /// exercises the FULL arm → tap → solve → accept path rather than stopping at a
    /// ghost. Returns whether anything was accepted.
    /// Accepts a pending Weave Fill proposal and returns the command it journaled.
    /// Installed by the shell, because the proposal slot lives on the Coordinator.
    /// Used by the visual-verification probe so it drives arm → tap → solve → ACCEPT
    /// rather than stopping at a ghost; the command comes back because `lastCommit`
    /// is how a probe reports that it journaled, and a fill commits through the
    /// Coordinator rather than this controller's own transaction path.
    var onAcceptWeaveFill: (() -> DocumentCommand?)?
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
    func send(_ command: DocumentCommand) {
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
            if let tool = activeTool, let context = contextProvider?() {
                if tool == .guide {
                    // Guide capture (add-guide-stroke-authoring) needs only a
                    // Target to raycast onto — no EditMesh.
                    if context.snapper != nil {
                        toolStroke = ToolStroke(tool: tool, context: context)
                    }
                } else if tool.isCameraManipulator || allowsStrokeAgainstLiveMesh(),
                    context.editObject != nil, context.editMesh != nil,
                    context.editPayload != nil, context.snapper != nil {
                    toolStroke = ToolStroke(tool: tool, context: context)
                }
            }
            return  // interpreted (grammar) or committed (tool) at stroke end
        }
        guard
            allowsStrokeAgainstLiveMesh(),
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
            // Where the stroke lands on the surface; a miss leaves it inert.
            guard let hit = surfacePoint(at: point(of: sample), in: context) else { return }
            newSession.anchor = hit
            if verb == .move {
                // Decided once, here, and never re-read: see `MoveScope`. NOT
                // gated on a vertex grab — an edge midpoint on a coarse cage
                // sits outside the vertex reach, and gating there made loop
                // scope unreachable.
                guard
                    let scope = Self.resolveMoveScope(
                        at: hit, in: mesh, sceneRadius: context.sceneRadius
                    )
                else { return }
                newSession.moveScope = scope
                // Only a scope that merges tracks a vertex to merge WITH.
                switch scope {
                case .vertex(let vertex), .surface(let vertex):
                    newSession.grabbedVertex = vertex
                    newSession.mergeRange = Self.mergeRange(
                        around: vertex, in: mesh, sceneRadius: context.sceneRadius
                    )
                case .loop:
                    break
                }
                onMoveScopeChanged?(scope.hint)
            } else {
                // Tweak: grab the nearest vertex, as it always has.
                guard
                    let pick = mesh.nearestVertex(
                        to: hit, maxDistance: context.sceneRadius * Self.vertexPickRadiusFraction
                    )
                else { return }
                newSession.grabbedVertex = pick.vertex
                newSession.mergeRange = Self.mergeRange(
                    around: pick.vertex, in: mesh, sceneRadius: context.sceneRadius
                )
            }
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
            if finished.moveScope != nil { onMoveScopeChanged?(nil) }
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
        if cancelled.moveScope != nil { onMoveScopeChanged?(nil) }
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
        // Pins (task 4.3, spec: "Pinned vertices … SHALL NOT be displaced
        // by Move, Relax, Auto Relax"): the document's pin set rides along
        // on EVERY brush sample, so the engine's PinSet holds the pinned
        // vertices fixed while their unpinned neighbours smooth.
        let pinned = context.annotations?.pinnedVertices ?? []
        do {
            switch current.verb {
            case .relax:
                try mesh.relax(
                    around: hit,
                    radius: radiusBase * Self.relaxRadiusFraction,
                    strength: Self.relaxStrength,
                    pinned: pinned,
                    snapping: context.snapper
                )
            case .erase:
                try mesh.erase(
                    around: hit,
                    baseRadius: radiusBase * Self.eraseBaseRadiusFraction,
                    pressure: Float(sample.pressure)
                )
            case .move:
                guard let scope = current.moveScope, let anchor = current.anchor else { return }
                let displacement = hit - anchor
                guard simd_length(displacement) > 0 else { return }
                switch scope {
                case .vertex(let vertex):
                    // Displacement, not placement at the touch: the grabbed
                    // vertex keeps its offset from the finger instead of
                    // jumping to it at the first sample.
                    try mesh.moveVertices(
                        [vertex], by: displacement, pinned: pinned, snapping: context.snapper
                    )
                case .loop(let vertices, _, _):
                    try mesh.moveVertices(
                        vertices, by: displacement, pinned: pinned, snapping: context.snapper
                    )
                case .surface(let seed):
                    guard mesh.vertexPosition(seed) != nil else { return }
                    try mesh.moveWithGeodesicFalloff(
                        seed: seed,
                        displacement: displacement,
                        radius: radiusBase * Self.moveRadiusFraction,
                        pinned: pinned,
                        snapping: context.snapper
                    )
                }
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

    /// How much of the grabbed vertex's OWN CELL another vertex must come
    /// within before the two count as the same point.
    ///
    /// Read it as how far the artist must drag: a merge engages only once the
    /// vertex is at least 70% of the way to its target. Half a cell was tried
    /// and is too eager — it merged a vertex nudged 60% toward a neighbour,
    /// which is a tweak, not an intent to join (a test caught it).
    nonisolated static let mergeRangeCellFraction: Float = 0.3

    /// Merge range for a drag, measured from the grabbed vertex's own cell —
    /// the mean length of the edges meeting it — rather than from the scene.
    ///
    /// A scene-relative window is the wrong shape twice over: on a coarse cage
    /// it is a fraction of a cell, so the artist has to land almost exactly on
    /// the target, and on a fine one it spans several cells and can merge a
    /// vertex the artist never aimed at. The cage's own spacing is what "close
    /// enough to be the same vertex" means.
    ///
    /// The scene-derived window survives ONLY as the answer for a vertex with no
    /// edges to measure. It must not be a floor under the cell-derived one: as a
    /// floor it simply wins on any cage smaller than the scene, which is every
    /// cage, and reinstates the bug (measured: 2.0 against a cell of 1).
    static func mergeRange(around vertex: UInt32, in mesh: Mesh, sceneRadius: Float) -> Float {
        guard let cell = cellSize(around: vertex, in: mesh) else {
            return sceneRadius * mergeSnapRadiusFraction
        }
        return cell * mergeRangeCellFraction
    }

    /// The local cell: the mean length of the edges meeting `vertex`, or nil
    /// when there is nothing to measure (an isolated vertex, an empty cage).
    ///
    /// Every tolerance that means "close, as the CAGE reckons it" is a fraction
    /// of this. A scene-relative one has been the defect four times over in this
    /// line of work — the merge window, the rim-bridge rung clearance, the
    /// mid-stroke guard, and Move's own grab radius — because a cage's spacing
    /// has nothing to do with how big the scene around it happens to be.
    nonisolated static func cellSize(around vertex: UInt32, in mesh: Mesh) -> Float? {
        guard let origin = mesh.vertexPosition(vertex) else { return nil }
        let live = mesh.edgeCount
        guard live > 0 else { return nil }
        var total: Float = 0
        var count = 0
        var seen = 0
        var id: UInt32 = 0
        // Sparse ids: the scan runs to the id CAPACITY, never to a
        // multiple of the live count (see `Mesh.edgeCapacity`).
        let limit = mesh.edgeCapacity
        while seen < live, Int(id) < limit {
            defer { id += 1 }
            guard let ends = mesh.edgeEndpoints(of: id) else { continue }
            seen += 1
            let other: UInt32
            if ends.0 == vertex {
                other = ends.1
            } else if ends.1 == vertex {
                other = ends.0
            } else {
                continue
            }
            guard let point = mesh.vertexPosition(other) else { continue }
            total += simd_distance(origin, point)
            count += 1
        }
        guard count > 0, total > 0 else { return nil }
        return total / Float(count)
    }

    /// How much of the local cell a touch may sit from a vertex and still count
    /// as ON that vertex, and from an edge and still count as ON that edge.
    ///
    /// SIZED FROM THE FACE INTERIOR, which is what makes these numbers what they
    /// are. Vertex and edge scope are targets the artist aims AT; the face is
    /// the default they fall back to, so it has to be the DOMINANT region of a
    /// cell — and an edge window is a band along every side, which eats area
    /// fast. For a square cell, the surface region is what is left inside all
    /// four bands: `(1 - 2e)²`. At the 0.35 first shipped that is 9% of the
    /// cell, and device testing found exactly what those numbers predict —
    /// starting a drag on a face almost never stretched the patch.
    ///
    /// A TRIANGLE sets the ceiling. Its farthest interior point from any edge is
    /// the incenter, and for the right-isoceles triangle a triangulated quad
    /// produces that is only ~0.26 of the mean edge. Any edge window at or above
    /// that covers the whole triangle, so surface scope inside one becomes
    /// unreachable at every touch position — not rare, impossible.
    ///
    /// At 0.15 the surface region is ~60% of a square cell and the triangle
    /// keeps a real core, while an edge still has a band 0.15 of a cell wide on
    /// either side to aim at.
    nonisolated static let vertexScopeCellFraction: Float = 0.25
    nonisolated static let edgeScopeCellFraction: Float = 0.15

    /// What a Move drag starting at `hit` should carry (spec:
    /// pencil-interaction / "Move's scope is what the drag starts on"), or nil
    /// when nothing is close enough to grab — in which case the stroke is inert,
    /// exactly as it was before this change.
    ///
    /// Order is vertex, then edge, then face. Vertex wins ties BECAUSE every
    /// vertex also lies on edges: an edge-first order would make single-vertex
    /// scope unreachable, which is the whole point of the feature.
    ///
    /// The scene-relative grab radius survives only as the outer bound that
    /// finds a candidate to measure the cell from, so starting anywhere on a
    /// face stays exactly as easy to hit as it is today.
    /// `nonisolated`: a pure query over a mesh, called both from the main-actor
    /// controller and from the nonisolated hover queries (design D1). Being
    /// synchronous, it runs in the caller's context and sends nothing anywhere.
    nonisolated static func resolveMoveScope(
        at hit: SIMD3<Float>, in mesh: Mesh, sceneRadius: Float
    ) -> MoveScope? {
        // Both candidates are gathered with the SAME generous reach first, and
        // only then judged against the cell-relative windows.
        //
        // The edge query must NOT be nested inside a successful vertex grab: on
        // a cage that is coarse relative to its scene, the midpoint of a cell can
        // sit outside the vertex reach entirely — a 2-unit cell in a scene of
        // radius 7 puts it at 1.0 against a reach of 0.85 — and gating on the
        // vertex made loop scope unreachable there, with the whole stroke inert.
        let reach = sceneRadius * vertexPickRadiusFraction
        let near = mesh.nearestVertex(to: hit, maxDistance: reach)
        let edge = mesh.nearestEdge(to: hit, maxDistance: reach)
        // The cell is measured from whichever anchor we have — the near vertex,
        // or failing that an endpoint of the near edge.
        let anchor = near?.vertex ?? edge.flatMap { mesh.edgeEndpoints(of: $0.edge)?.0 }
        guard let anchor else { return nil }
        // No edges to measure means no edges to pick either: an isolated vertex
        // can only ever be moved alone.
        guard let cell = cellSize(around: anchor, in: mesh) else {
            return .vertex(anchor)
        }
        if let near, simd_distance(hit, near.position) <= cell * vertexScopeCellFraction {
            return .vertex(near.vertex)
        }
        if let edge, simd_distance(hit, edge.point) <= cell * edgeScopeCellFraction {
            let loop = mesh.edgeLoopVertices(from: edge.edge)
            if loop.count >= 3 {
                return .loop(loop, edge: edge.edge, seed: anchor)
            }
            // The loop could not be walked end to end — a pole, a boundary, a
            // neighbourhood that is not quad-regular. A drag that visibly
            // grabbed an edge still has to move something, so it moves that
            // edge.
            if let ends = mesh.edgeEndpoints(of: edge.edge) {
                return .loop([ends.0, ends.1], edge: edge.edge, seed: anchor)
            }
        }
        // Surface scope needs a seed vertex; without one the stroke is inert,
        // exactly as it was before this change.
        guard let near else { return nil }
        return .surface(seed: near.vertex)
    }

    /// Merge-snap detection (task 3.7, spec scenario "Snap feedback"): when
    /// the DRAGGED vertex (Tweak target / Move seed) sits within merge
    /// range of another vertex, that target pre-highlights — before
    /// anything commits — and `commit` finalizes the merge at stroke end.
    /// Engine-side query (design D1) excluding the dragged vertex itself
    /// (which is always nearest to its own position).
    private func updateSnapDetection(for current: Session, mesh: Mesh) {
        guard current.verb == .tweak || current.verb == .move,
            let grabbed = current.grabbedVertex
        else { return }
        // A loop drag never merges, so it never offers a candidate to merge
        // WITH: no highlight, no tick, nothing to finalize at release.
        if current.verb == .move, current.moveScope?.mergesOnRelease == false { return }
        var candidate: HoverPreviewState.SnapTarget?
        if let dragged = mesh.vertexPosition(grabbed),
            let pick = mesh.nearestVertex(
                to: dragged, maxDistance: current.mergeRange, excluding: grabbed
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
        // Merge-snap finalization (task 3.7): a snap candidate held at stroke
        // end commits INSIDE the same journaled transaction — exactly one
        // journal entry for grab + drag + merge.
        //
        // BOTH verbs merge now. Move used to weld the seed's POSITION onto the
        // target and leave the topology alone, on the reasoning that collapsing
        // it under a whole-falloff drag would surprise; in practice it produced
        // two coincident vertices where the artist plainly meant one. Only the
        // SEED merges either way — the vertex under the finger, never anything
        // the falloff carried along — so the region still keeps its structure.
        let candidate = snapFeedback.candidate
        // The scope names the entry — `move.vertex`, `move.loop`, and a bare
        // `move` for surface so existing history keeps its meaning.
        var verb = finished.verb.rawValue + (finished.moveScope?.verbSuffix ?? "")
        var merged = false
        lastCommit = nil
        journalOrDiscard(verb: verb) {
            if let candidate, let grabbed = finished.grabbedVertex,
                let mesh = finished.context.editMesh,
                finished.verb == .tweak
                    || (finished.verb == .move
                        && finished.moveScope?.mergesOnRelease != false) {
                try mesh.mergeVertices(keep: candidate.vertex, remove: grabbed)
                verb += ".mergeSnap"
                merged = true
                onLiveEdit?()
            }
            return try finished.transaction.command(verb: verb)
        }
        // Tick ON commit (highlight was live during the drag): only when
        // a snap/merge was engaged AND its command reached the journal. Read
        // from `merged`, NOT from the verb differing — the scope suffix makes
        // the verb differ on every scoped drag, merge or no merge.
        let snapCommitted = merged && lastCommit != nil
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
            if interpretation.candidates.contains(where: {
                $0.action == .createQuad || $0.action == .createTriangle
            }), (3...4).contains(interpretation.quadCorners.count) {
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
        case .createQuad, .createTriangle:
            // Quad (4 corners) and triangle (3) share one welded create path;
            // createWeldedFace/buildFace accept either ring size.
            let sides = best.action == .createTriangle ? 3 : 4
            guard interpretation.quadCorners.count == sides else { return }
            let verb = best.action == .createTriangle
                ? "pencil.createTriangle" : "pencil.createQuad"
            let mergeRadius = context.sceneRadius * Self.mergeSnapRadiusFraction
            applyCreate(
                verb: verb,
                screenPoints: interpretation.quadCorners,
                context: context
            ) { mesh, corners, snapper in
                // A face drawn against an existing edge welds onto it (task 4)
                // instead of floating free; drawn against a SUBDIVIDED boundary
                // it continues that boundary's loops as a welded patch.
                try Self.buildCreatedFace(
                    mesh: mesh, corners: corners, snapper: snapper, mergeRadius: mergeRadius
                )
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
                context: context,
                layout: .grid(cols: grid.cols)
            ) { mesh, lattice, snapper in
                try mesh.createGrid(
                    lattice: lattice, rows: grid.rows, cols: grid.cols, snapping: snapper
                )
            }
        case .insertLoop:
            let ring = elementIDs(of: best, kind: .edge)
            guard let seed = ring.first else { return }
            applyElementEdit(
                verb: "pencil.insertLoop", context: context,
                autoRelaxAround: autoRelaxPoints(of: best.elements, mesh: context.editMesh)
            ) { mesh in
                // Capture the crossed edge's midpoint BEFORE the insert
                // renumbers it, so the symmetric sides can be resolved by
                // position afterwards.
                let midpoint = mesh.edgeEndpoints(of: seed).flatMap {
                    ends -> SIMD3<Float>? in
                    guard let a = mesh.vertexPosition(ends.0),
                        let b = mesh.vertexPosition(ends.1)
                    else { return nil }
                    return (a + b) * 0.5
                }
                try mesh.insertLoop(acrossEdge: seed)
                // Symmetric insert (task 4.4a): insert the same loop across
                // each mirror / rotational counterpart edge. The primary
                // insert only renumbered its OWN side, so the disjoint mirror
                // regions are still resolvable by position; best-effort per
                // side (a side whose counterpart is not a valid ring edge is
                // skipped rather than failing the whole stroke).
                guard let midpoint else { return }
                for edge in self.mirrorCounterparts(
                    of: [midpoint], kind: .edge, mesh: mesh, context: context
                ) {
                    try? mesh.insertLoop(acrossEdge: edge)
                }
            }
        case .bridgeRims:
            // The recognizer names ONE corresponding pair of rim vertices; the
            // walk that fills the corridor between their rims lives in the
            // engine facade. NO auto-relax: the spec requires rim vertices not
            // to move, and the relax pass moves whatever is near the edit.
            let vertices = elementIDs(of: best, kind: .vertex)
            guard vertices.count == 2 else { return }
            applyElementEdit(verb: "pencil.bridgeRims", context: context) { mesh in
                // A pair that cannot be bridged throws, and the journaled path
                // discards the transaction — the stroke does nothing rather
                // than leaving a half-built strip.
                try mesh.bridgeRims(
                    from: vertices[0], to: vertices[1], snapping: context.snapper
                )
            }
        case .dissolveEdge:
            let edges = elementIDs(of: best, kind: .edge)
            guard !edges.isEmpty else { return }
            applyElementEdit(
                verb: "pencil.dissolveEdge", context: context,
                autoRelaxAround: autoRelaxPoints(of: best.elements, mesh: context.editMesh)
            ) { mesh in
                try mesh.dissolveEdges(edges)
            }
        case .deleteFaces:
            let faces = elementIDs(of: best, kind: .face)
            guard !faces.isEmpty else { return }
            // 6.2b: the X gesture is STAGE-DEPENDENT — "X over faces/region/component ->
            // delete (RT) / unwrap (UV) / bake (BK)". Dispatched here rather than by
            // remapping the recognizer's action, because the recognizer reports the SHAPE it
            // saw and what a shape MEANS is a document-state question it has no business
            // knowing.
            switch Self.crossMeaning(in: context.stage) {
            case .deleteFaces:
                break  // fall through to the delete below
            case .reunwrapIsland:
                reunwrapIsland(containingAnyOf: faces, context: context)
                return
            case .inert:
                // An unimplemented stage does NOTHING. Falling back to deletion is how this
                // gesture silently destroyed geometry in the UV stage before 6.2b, so the
                // default must be inert rather than destructive.
                return
            }
            // Auto Relax (task 4.5a) evens the topology around the hole. The
            // neighbourhood is the deleted faces' rings, resolved BEFORE the
            // delete runs (the argument is evaluated first, while the faces
            // are still alive) via the engine `faceVertices` query.
            applyElementEdit(
                verb: "pencil.deleteFaces", context: context,
                autoRelaxAround: autoRelaxPoints(of: best.elements, mesh: context.editMesh)
            ) { mesh in
                // Symmetric delete (task 4.4a): also delete the mirror /
                // rotational counterpart faces, resolved by centroid. Batched
                // into ONE delete, so there is no id renumbering between sides.
                let centroids = faces.compactMap { mesh.faceCentroid($0) }
                var all = Set(faces)
                for id in self.mirrorCounterparts(
                    of: centroids, kind: .face, mesh: mesh, context: context
                ) {
                    all.insert(id)
                }
                try mesh.deleteFaces(Array(all))
            }
        case .mergeVertices:
            // The stroke's start vertex snaps onto its end vertex.
            let vertices = elementIDs(of: best, kind: .vertex)
            guard vertices.count == 2 else { return }
            applyElementEdit(
                verb: "pencil.mergeVertices", context: context,
                autoRelaxAround: autoRelaxPoints(of: best.elements, mesh: context.editMesh)
            ) { mesh in
                try mesh.mergeVertices(keep: vertices[1], remove: vertices[0])
            }
        case .rotateEdge:
            guard let edge = elementIDs(of: best, kind: .edge).first else { return }
            applyElementEdit(
                verb: "pencil.rotateEdge", context: context,
                autoRelaxAround: autoRelaxPoints(of: best.elements, mesh: context.editMesh)
            ) { mesh in
                try mesh.rotateEdge(edge)
            }
        case .tagLoop:
            let loop = elementIDs(of: best, kind: .edge)
            guard !loop.isEmpty else { return }
            applyAnnotationEdit(verb: "pencil.tagLoop", context: context) { annotations in
                annotations.togglingTags(on: loop, color: self.activeTagColor)
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

    /// What an X (`.cross`, reported as `.deleteFaces`) means in a given stage.
    ///
    /// ONE switch, consulted by both the apply path and the alternative-swap path, so the two
    /// cannot drift into disagreeing about whether an X deletes. A second copy is how the
    /// chip would end up offering "Delete faces" as an alternative in a stage where the
    /// gesture does not delete.
    enum CrossMeaning: Equatable, Sendable {
        case deleteFaces
        case reunwrapIsland
        case inert
    }

    // `nonisolated`: a pure function of the stage, touching no instance state. The chip
    // builder is not main-actor isolated and must consult the SAME rule as the apply path.
    nonisolated static func crossMeaning(in stage: DocumentManifest.Stage?) -> CrossMeaning {
        switch stage {
        case .retopology:
            return .deleteFaces
        case .uv:
            return .reunwrapIsland
        case .baking:
            // Bake-on-X is Phase 7. Inert until then, which is the safe direction.
            return .inert
        case nil:
            // An unset stage is NOT retopology. Treating it as retopology would make every
            // context that forgot to set a stage silently destructive, which is precisely the
            // failure mode this whole dispatch exists to remove.
            return .inert
        }
    }

    private func canBuildReplacement(
        _ candidate: StrokeInterpretation.Candidate, stroke: AppliedPencilStroke
    ) -> Bool {
        switch candidate.action {
        case .insertLoop, .tagLoop, .dissolveEdge, .rotateEdge:
            return !elementIDs(of: candidate, kind: .edge).isEmpty
        case .deleteFaces:
            // Never offer a delete as an alternative in a stage where an X does not delete.
            guard Self.crossMeaning(in: contextProvider?()?.stage) == .deleteFaces else {
                return false
            }
            return !elementIDs(of: candidate, kind: .face).isEmpty
        case .hideRegion:
            return !elementIDs(of: candidate, kind: .face).isEmpty
        case .mergeVertices, .bridgeRims:
            return elementIDs(of: candidate, kind: .vertex).count == 2
        case .createQuad:
            return stroke.worldCorners?.count == 4
        case .createTriangle:
            return stroke.worldCorners?.count == 3
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
        case .bridgeRims:
            let vertices = elementIDs(of: candidate, kind: .vertex)
            guard vertices.count == 2 else { return nil }
            try mesh.bridgeRims(
                from: vertices[0], to: vertices[1], snapping: contextProvider?()?.snapper
            )
            verb = "pencil.bridgeRims"
        case .createQuad, .createTriangle:
            let sides = candidate.action == .createTriangle ? 3 : 4
            guard let corners = stroke.worldCorners, corners.count == sides else { return nil }
            // Weld like the live gesture path, so a swap shares edges
            // identically (task 4).
            let context = contextProvider?()
            try Self.buildCreatedFace(
                mesh: mesh, corners: corners,
                snapper: context?.snapper,
                mergeRadius: (context?.sceneRadius ?? 1) * Self.mergeSnapRadiusFraction
            )
            verb = candidate.action == .createTriangle
                ? "pencil.createTriangle" : "pencil.createQuad"
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
    /// - Parameter autoRelaxAround: world points describing the region the
    ///   edit touched. When Auto Relax is on (task 4.5) the redistribution
    ///   pass runs over exactly that neighborhood, INSIDE this same
    ///   transaction — one journal entry for edit + relax. Empty disables
    ///   the pass for this edit.
    func applyElementEdit(
        verb: String, context: Context, autoRelaxAround: [SIMD3<Float>] = [],
        _ mutate: @escaping (Mesh) throws -> Void
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
            try runAutoRelaxIfEnabled(mesh: mesh, context: context, around: autoRelaxAround)
            onLiveEdit?()
            return try transaction.command(verb: verb)
        }
    }

    // MARK: Annotation edits (loop tags + visibility, task 3.4)

    /// Journals an annotation change as ONE `annotationEdit` command.
    /// Annotations are manifest state — payload bytes never move, and a
    /// no-op transform journals nothing.
    func applyAnnotationEdit(
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
    /// - Parameter layout: how `screenPoints` are laid out, so a
    ///   REFLECTING symmetry replica can reorder them and keep the created
    ///   faces' winding (task 4.4).
    /// Largest number of columns a single continued patch may span — a guard
    /// against a runaway extrusion from a stray cell-size estimate.
    static let maxPatchDimension = 24

    /// A drawn quad's shorter side must span at least this many neighbour cells
    /// before it is treated as a patch that CONTINUES the neighbour's loops (as
    /// opposed to a plain one-cell append, which stays a single quad).
    static let patchContinuationMinCells: Float = 1.5

    /// Builds a created face from a recognized quad/triangle ring. When a quad
    /// is drawn against an existing SUBDIVIDED boundary (e.g. the multi-row edge
    /// of an existing grid), its shared side's boundary chain is extruded across
    /// the drawn region — the new quads WELD onto that boundary and CONTINUE its
    /// edge loops (CozyBlanket-style patch fill). A triangle, a standalone quad,
    /// or a one-cell append (no subdivided neighbour) is a single welded face.
    static func buildCreatedFace(
        mesh: Mesh, corners: [SIMD3<Float>], snapper: SurfaceSnapper?, mergeRadius: Float
    ) throws {
        if corners.count == 4,
            try continueAdjacentBoundary(
                mesh: mesh, corners: corners, snapper: snapper, mergeRadius: mergeRadius
            )
        {
            return
        }
        try mesh.createWeldedFace(at: corners, mergeRadius: mergeRadius, snapping: snapper)
    }

    /// When the drawn quad lands against a subdivided existing boundary, extends
    /// that boundary's vertex chain across the drawn region (welded rows that
    /// continue the neighbour's loops) and returns `true`. Returns `false` with
    /// the mesh UNCHANGED when there is no such neighbour, so the caller falls
    /// back to a single welded face. Any engine rejection also returns `false`.
    private static func continueAdjacentBoundary(
        mesh: Mesh, corners: [SIMD3<Float>], snapper: SurfaceSnapper?, mergeRadius: Float
    ) throws -> Bool {
        // Snap radius capped to the quad's own scale, matching createWeldedFace:
        // a corner may only reuse a vertex sitting ~on it, never a distant one.
        var shortestEdge = Float.greatestFiniteMagnitude
        for i in 0..<4 {
            shortestEdge = min(shortestEdge, simd_distance(corners[i], corners[(i + 1) % 4]))
        }
        guard shortestEdge.isFinite, shortestEdge > 1e-6 else { return false }
        let radius = min(mergeRadius, shortestEdge * 0.35)

        // Look for a quad SIDE that FOLLOWS an existing rim (change
        // fix-quad-rim-sharing). The test used to be that the side's two CORNERS
        // both snapped to existing vertices, which an L-derived ring can never
        // satisfy: its bend and its inferred fourth corner hang in mid-air, and its
        // two existing vertices sit diagonally opposite, never on one side. So the
        // rim the artist actually drew along was invisible here, and the side came
        // out as one long edge with every rim vertex T-junctioned against it.
        for i in 0..<4 {
            let j = (i + 1) % 4
            let sharedMid = (corners[i] + corners[j]) * 0.5
            // How far off the rim a HAND-DRAWN side may sit and still count as
            // following it — a fraction of the side's own length, since a stroke's
            // error scales with what it drew, not with the scene's size. `rimRun`
            // then refines this against the rim's own cell, so it can be generous.
            let sideLength = simd_distance(corners[i], corners[j])
            let follow = max(radius, sideLength * rimRunFollowFraction)
            guard let chain = rimRun(
                mesh: mesh, from: corners[i], to: corners[j], tolerance: follow
            ), chain.count >= 3
            else { continue }  // needs a genuinely SUBDIVIDED neighbour (≥2 cells)

            // Mean neighbour cell size along the shared chain.
            var segSum: Float = 0
            for k in 1..<chain.count {
                guard let p = mesh.vertexPosition(chain[k - 1]),
                    let q = mesh.vertexPosition(chain[k])
                else { continue }
                segSum += simd_distance(p, q)
            }
            let cell = segSum / Float(chain.count - 1)
            guard cell > 1e-6 else { continue }

            // The shared side must span several neighbour cells to count as a
            // patch — a one-cell append stays a single quad.
            let sharedSide = simd_distance(corners[i], corners[j])
            guard sharedSide >= cell * patchContinuationMinCells else { continue }

            // Extrude from the shared side toward the opposite (far) side.
            let farMid = (corners[(i + 2) % 4] + corners[(i + 3) % 4]) * 0.5
            let offsetVec = farMid - sharedMid
            let depth = simd_length(offsetVec)
            guard depth > 1e-6 else { continue }
            let rings = max(1, min(maxPatchDimension, Int((depth / cell).rounded())))
            let perRing = offsetVec / Float(rings)
            do {
                // ONE ROW AT A TIME, so each row can close onto whatever rim it lands
                // on before the next is stepped off it. `extendBoundary` reports the
                // row it just made (`outerChain`), which is the only trustworthy name
                // for it — a live-vertex-id diff around the call is not, and welding
                // off such a diff collapsed the patch it was meant to close.
                var row = chain
                var built = 0
                for _ in 0..<rings {
                    let extended = try mesh.extendBoundary(
                        chain: row, closed: false, offset: perRing, rings: 1, snapping: snapper
                    )
                    guard extended.newFaces > 0 else { break }
                    built += extended.newFaces
                    // A patch filling the inside of an L lands ON the second rim the
                    // stroke followed. Weld this row onto that rim so the patch MEETS
                    // it instead of laying a duplicate row over it.
                    //
                    // Measured in the patch's OWN CELL, not in scene units: a row is
                    // placed from the drawn ring's estimated corners, so it lands a few
                    // percent of a cell off the rim it means to meet (0.04 and 0.08 of
                    // a unit cell in the regression fixture) — near enough to be the
                    // same point, but well outside a scene-derived pick radius, which
                    // is what left the duplicates. A third of a cell cannot reach the
                    // row behind it, so the bound still holds.
                    let placed = extended.outerChain.compactMap { mesh.vertexPosition($0) }
                    guard placed.count == extended.outerChain.count else { break }
                    try mesh.weldNewVerticesOntoExisting(
                        Set(extended.outerChain), mergeRadius: cell * 0.35
                    )
                    // Step the NEXT row off where this one actually ended up: a welded
                    // vertex is dead, and its keeper is the rim vertex it folded onto.
                    row = zip(extended.outerChain, placed).compactMap { id, position in
                        mesh.vertexPosition(id) != nil
                            ? id
                            : mesh.nearestVertex(to: position, maxDistance: cell * 0.35)?.vertex
                    }
                    guard row.count == extended.outerChain.count else { break }
                }
                if built > 0 { return true }
            } catch {
                // A non-boundary chain / winding rejection: leave the mesh for
                // the single-quad fallback rather than losing the stroke.
                return false
            }
        }
        return false
    }

    /// A side must cover at least this fraction of its length with the rim's own
    /// vertices before it counts as FOLLOWING that rim. A side that merely touches
    /// a rim near one end is an append, not a traced edge.
    static let rimRunMinCoverage: Float = 0.6

    /// How far off a rim a hand-drawn side may sit, as a fraction of that side's own
    /// length, and still count as following it. Kept well under half a cell by the
    /// self-consistency check at the call site.
    static let rimRunFollowFraction: Float = 0.12

    /// The boundary chain through the nearest BOUNDARY edge to `point` within
    /// `radius`. Edge ids are sparse, so this probes past the live count rather than
    /// assuming density (the scan `WeaveFillDomain.openBoundaryEdges` also does).
    static func nearestBoundaryChain(
        mesh: Mesh, to point: SIMD3<Float>, within radius: Float
    ) -> Mesh.BoundaryChain? {
        let live = mesh.edgeCount
        guard live > 0 else { return nil }
        var best: (edge: UInt32, distance: Float)?
        var seen = 0
        var id: UInt32 = 0
        // Sparse ids: the scan runs to the id CAPACITY, never to a
        // multiple of the live count (see `Mesh.edgeCapacity`).
        let limit = mesh.edgeCapacity
        while seen < live, Int(id) < limit {
            defer { id += 1 }
            guard let ends = mesh.edgeEndpoints(of: id) else { continue }
            seen += 1
            guard mesh.isBoundaryEdge(id) == true,
                let a = mesh.vertexPosition(ends.0), let b = mesh.vertexPosition(ends.1)
            else { continue }
            // Distance to the SEGMENT, not to its midpoint: a side lying exactly
            // along a rim sits half a cell from every edge midpoint on it, so a
            // midpoint test finds nothing precisely when the answer is "this one".
            let span = b - a
            let lengthSquared = simd_length_squared(span)
            let closest = lengthSquared > 1e-12
                ? a + span * simd_clamp(simd_dot(point - a, span) / lengthSquared, 0, 1)
                : a
            let distance = simd_distance(closest, point)
            if distance <= radius, distance < (best?.distance ?? .greatestFiniteMagnitude) {
                best = (id, distance)
            }
        }
        guard let best else { return nil }
        return mesh.boundaryChain(through: best.edge)
    }

    /// The run of consecutive boundary-chain vertices that the drawn side
    /// `start → end` FOLLOWS: each within `tolerance` of the segment and projecting
    /// inside it, ordered from the `start` end. nil when the side follows no rim.
    ///
    /// Geometric on purpose. The corner-based predecessor asked whether the side's
    /// two ENDS were existing vertices, which says nothing about the cells between
    /// them and is unanswerable for a ring whose corners were inferred from a bend.
    /// What matters is whether the artist drew ALONG existing topology, and that is
    /// a question about the rim's vertices, not the ring's corners.
    static func rimRun(
        mesh: Mesh, from start: SIMD3<Float>, to end: SIMD3<Float>, tolerance: Float
    ) -> [UInt32]? {
        let span = end - start
        let length = simd_length(span)
        guard length > 1e-6 else { return nil }
        let direction = span / length
        // Seed on the nearest BOUNDARY edge to the side's middle. Asking for the
        // nearest edge and then testing whether it happens to be a boundary (what the
        // predecessor did) fails exactly here: a side traced along a rim has that
        // rim's INTERIOR neighbours only half a cell away, so the nearest edge is
        // often an interior one and the whole continuation bailed out. Bounded, too —
        // an unbounded search always finds something, however distant.
        guard let loop = nearestBoundaryChain(
            mesh: mesh, to: (start + end) * 0.5, within: tolerance
        ) else { return nil }

        /// Does this rim vertex lie ON the drawn side, within `slack`?
        func onSide(_ vertex: UInt32, _ slack: Float) -> Bool {
            guard let point = mesh.vertexPosition(vertex) else { return false }
            let along = simd_dot(point - start, direction)
            guard along >= -slack, along <= length + slack else { return false }
            return simd_distance(point, start + direction * along) <= slack
        }

        /// Longest consecutive run of on-side vertices, wrapping only on a closed loop.
        func longestRun(_ slack: Float) -> [UInt32] {
            let ring = loop.vertices
            guard !ring.isEmpty else { return [] }
            let reach = loop.closed ? ring.count * 2 - 1 : ring.count
            var best: [UInt32] = []
            var current: [UInt32] = []
            for step in 0..<reach {
                let index = step % ring.count
                if loop.closed, step >= ring.count, current.isEmpty { break }
                if onSide(ring[index], slack), !current.contains(ring[index]) {
                    current.append(ring[index])
                    if current.count > best.count { best = current }
                } else {
                    current = []
                }
            }
            return best
        }

        // Two passes. The first is generous, because how far a HAND-DRAWN side sits
        // off the rim scales with what was drawn. But "generous" has to be judged
        // against the rim's CELL — a slack of half a cell would sweep in a PARALLEL
        // rim one cell away and extrude the patch from the wrong chain — and the cell
        // is only knowable once a run exists. So the run measures its own cell and
        // re-filters against it. Refining beats rejecting: a side spanning many cells
        // legitimately needs a slack that is a small fraction of ITSELF and a large
        // one of a single cell, and a one-shot tolerance cannot be both.
        var best = longestRun(tolerance)
        if best.count >= 2 {
            var total: Float = 0
            var cells = 0
            for index in 1..<best.count {
                guard let p = mesh.vertexPosition(best[index - 1]),
                    let q = mesh.vertexPosition(best[index])
                else { continue }
                total += simd_distance(p, q)
                cells += 1
            }
            if cells > 0, total > 0 {
                let refined = min(tolerance, total / Float(cells) * 0.35)
                if refined < tolerance { best = longestRun(refined) }
            }
        }
        guard best.count >= 2 else { return nil }
        // The run has to actually COVER the side, not just touch it near one end.
        guard let first = mesh.vertexPosition(best[0]),
            let last = mesh.vertexPosition(best[best.count - 1]),
            simd_distance(first, last) >= length * rimRunMinCoverage
        else { return nil }
        // Ordered from the side's start, so the extrusion's offset points across it.
        return simd_dot(first - start, direction) <= simd_dot(last - start, direction)
            ? best : best.reversed()
    }

    func applyCreate(
        verb: String, screenPoints: [SIMD2<Float>], context: Context,
        layout: SymmetryPointLayout = .ring,
        _ build: @escaping (Mesh, [SIMD3<Float>], SurfaceSnapper?) throws -> Void
    ) {
        guard
            context.snapper != nil,
            let authored = unprojectCorners(screenPoints, in: context)
        else { return }
        // SYMMETRY (task 4.4): the authored operation and every symmetric
        // copy of it are the SAME engine operation run with transformed
        // input, all inside the one transaction below — so the journal
        // holds a single command whose effect is already symmetric and one
        // undo removes every side together. Nothing is duplicated after
        // the fact.
        let symmetry = context.effectiveSymmetry.weldScaled(sceneRadius: context.sceneRadius)
        let copies = [authored] + symmetry.replicas.map {
            $0.apply(points: authored, layout: layout)
        }
        let buildAll: (Mesh, [SIMD3<Float>], SurfaceSnapper?) throws -> Void = {
            mesh, _, snapper in
            // Capture what EACH copy creates (a live-id diff around its build)
            // only when we will weld the seam — the scan is wasted otherwise.
            // This is the provenance the seam weld needs: after the Target and
            // plane snaps move a vertex, its position no longer says which copy
            // authored it (task 4.4b).
            let capture = symmetry.isActive
            var created: [[UInt32]] = []
            created.reserveCapacity(copies.count)
            for copy in copies {
                let before = capture ? mesh.liveVertexIDs() : []
                try build(mesh, copy, snapper)
                if capture {
                    created.append(Array(mesh.liveVertexIDs().subtracting(before)))
                }
            }
            // Center-line vertices snap onto every enabled mirror plane
            // (spec: "Center-line vertices SHALL snap to the symmetry
            // plane") — inside the same transaction, so the weld is part
            // of the one command the stroke journals.
            if symmetry.isActive {
                try mesh.snapToSymmetryPlanes(symmetry)
                // ...and WELD the seam. Snapping only moves positions, so
                // the authored copy and the mirrored copy each still own
                // their own vertex on the plane: without this merge the
                // center line is a crack (two coincident-but-unshared
                // vertices per corner), which boundary walks, Relax/Move
                // and export all read as an open rim. Same transaction, so
                // one undo removes the whole symmetric create.
                // PROVENANCE weld (task 4.4b): pair each copy's seam vertex
                // with its twins by the RING they came from, not by where the
                // snap left them — so the seam closes even on an asymmetric
                // Target that snapped the mirrored copy differently.
                try mesh.weldSeamVertices(
                    symmetry, rings: copies, created: created,
                    searchRadius: context.sceneRadius * Self.vertexPickRadiusFraction
                )
            }
            // AUTO RELAX (task 4.5): still inside the stroke's ONE
            // transaction, so the append and the redistribution it triggers
            // are a single undo step. The neighborhood is every authored
            // copy, so a mirrored create relaxes both sides.
            try self.runAutoRelaxIfEnabled(
                mesh: mesh, context: context, around: copies.flatMap { $0 }
            )
        }
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
                try buildAll(mesh, authored, context.snapper)
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
                try buildAll(mesh, authored, context.snapper)
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

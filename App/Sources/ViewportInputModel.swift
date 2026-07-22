import CoreGraphics
import CyberKit
import CyberKitTesting
import Foundation
import Observation
import QuartzCore
import os

/// Observable bridge between SwiftUI (verb toolbar, stroke HUD) and the
/// viewport's `ViewportInputController`. One instance
/// per open editor; the `MetalViewport` coordinator binds the controller's
/// UIKit side to the same instance, so toolbar holds and viewport touches
/// arbitrate through a single `InputArbiter`.
///
/// Task 3.2: completed strokes flow from the capture pipeline into the
/// ENGINE two-stage recognizer (`StrokeRecognizerConsumer` →
/// `cyber_stroke_interpret`; both stages run in C++, design D1/D5) and the
/// resulting interpretation record is published for the debug HUD. No mesh
/// mutation happens here — applying interpretations is tasks 3.3/3.4, via
/// the journaled `DocumentCommand` path.
@MainActor
@Observable
final class ViewportInputModel {
    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "CyberTopology",
        category: "stroke-interpretation"
    )

    let controller: ViewportInputController

    /// Engine recognizer consumer: the exact same object the regression
    /// suite drives with replayed fixtures, so live strokes and fixture
    /// replays exercise one code path.
    @ObservationIgnored private let recognizer = StrokeRecognizerConsumer()
    /// Interpretation of the stroke currently being finalized; consumed by
    /// `publish` so a failed interpretation can never leak a stale record
    /// into the next stroke's HUD entry.
    @ObservationIgnored private var pendingInterpretation: StrokeInterpretation?

    /// Mirror of the arbiter's active verb for toolbar highlighting.
    private(set) var activeVerb: InputArbiter.Verb = .pencil
    /// Bounding sphere of the loaded scene, mirrored from the renderer
    /// (task 4.4): the symmetry settings' origin sliders span it so the
    /// mirror plane can be placed anywhere through the model.
    private(set) var sceneCenter: SIMD3<Float> = .zero
    private(set) var sceneRadius: Float = 1

    /// Publishes the renderer's scene bounds. Called by the viewport
    /// coordinator whenever geometry loads or reloads.
    func setSceneBounds(center: SIMD3<Float>, radius: Float) {
        guard center != sceneCenter || radius != sceneRadius else { return }
        sceneCenter = center
        sceneRadius = radius
    }
    /// Armed retopology tool (task 4.1): while set (and the Pencil verb is
    /// active), Pencil strokes drive the tool instead of the gesture
    /// grammar. Selecting any verb persistently — toolbar tap, quick-verb
    /// palette, gesture-requested switch — disarms; spring-loaded verb
    /// HOLDS override only for their duration and restore the tool after.
    private(set) var activeTool: RetopoTool?
    /// One-line description of the last captured stroke (debug HUD; the
    /// task-3.5 interpretation chip is the user-facing surface, this stays
    /// as the raw capture-side diagnostic for ALL verbs).
    private(set) var lastStrokeSummary: String?
    /// Interpretation record of the last completed stroke (nil when the
    /// recognizer failed or no stroke finished yet). Drives the DEBUG
    /// stroke HUD; the task-3.5 interpretation chip consumes the same
    /// record through `MeshEditController.onPencilStrokeResolved`.
    private(set) var lastInterpretation: StrokeInterpretation?
    /// Normalized-viewport polyline of the last completed stroke (DEBUG
    /// stroke HUD overlay).
    private(set) var lastStrokePolyline: [CGPoint] = []

    /// Post-stroke interpretation chip (task 3.5, spec: pencil-interaction /
    /// "Post-stroke interpretation chip"): transient content published for
    /// the editor overlay; nil = hidden. Auto-dismisses after
    /// `chipDismissDelay` and is dismissed the moment the NEXT stroke
    /// begins — the chip never blocks or outlives further input.
    private(set) var interpretationChip: InterpretationChipState.Chip?
    /// The pure chip state machine (unit-tested transitions).
    @ObservationIgnored private var chipMachine = InterpretationChipState()
    /// Auto-dismiss delay; injectable so tests do not sleep for seconds.
    @ObservationIgnored var chipDismissDelay: Duration = .seconds(6)
    @ObservationIgnored private var chipDismissTask: Task<Void, Never>?

    /// Pencil Pro quick-verb palette (task 3.7, spec: "Pencil Pro squeeze
    /// SHALL open a radial Action Gallery at the pen tip" — this is the
    /// minimal five-verb ring; the full gallery is 3.8). nil = hidden.
    /// Dismisses the moment any stroke begins, like the chip.
    private(set) var quickVerbPalette: QuickVerbPaletteState.Palette?
    /// The pure squeeze → palette state machine (unit-tested transitions).
    @ObservationIgnored private var paletteMachine = QuickVerbPaletteState()

    /// Pencil Pro barrel-roll angle in radians (task 3.7), forwarded from
    /// the viewport's hover recognizer — non-zero only on hardware that
    /// reports it. Rotate-placed-element consumers (task 3.7a → 4.2): the
    /// camera-as-manipulator sessions (Patch Clone spins the pending
    /// patch, Transform Vertices spins the selection) receive it through
    /// `MeshEditController.barrelRollChanged`; `onBarrelRollChanged`
    /// stays as the observable test seam.
    private(set) var barrelRollAngle: Float = 0
    @ObservationIgnored var onBarrelRollChanged: ((Float) -> Void)?

    /// Camera-as-manipulator session banner (task 4.2): non-nil while a
    /// Patch Clone / Extend Boundary / Transform Vertices session is
    /// armed; drives the editor's session controls and mirrors the
    /// arbiter's camera→tool gate.
    private(set) var cameraToolBanner: MeshEditController.CameraToolBanner?
    /// Transient tool status line (the Transform Vertices re-snap
    /// report); replaced by the next report, cleared with the session UI.
    private(set) var cameraToolStatus: String?

    /// Fired the moment ANY stroke begins (before the verb layer sees it).
    /// Task 3.6: the viewport coordinator clears the hover preview here —
    /// a preview must never linger under live authoring.
    @ObservationIgnored var onStrokeWillBegin: (() -> Void)?
    /// Hover-preview controller (task 3.6), installed by the viewport
    /// coordinator alongside `meshEditor`. Weak: the coordinator owns it.
    /// Exposed so the editor's UI-test/screenshot hooks can drive hover
    /// probes (the simulator has no Pencil hover hardware).
    @ObservationIgnored weak var hoverPreview: HoverPreviewController?

    /// Mesh-edit controller for the verb layer (tasks 3.3/3.4), installed
    /// by the viewport coordinator (it owns the renderer/camera the
    /// controller needs). Stroke events are forwarded below; nil = strokes
    /// stay capture-and-interpret only. Gesture-requested verb switches
    /// (double-tap → Tweak) route back through `selectVerb` so the arbiter
    /// and toolbar highlight stay in sync.
    @ObservationIgnored var meshEditor: MeshEditController? {
        didSet {
            meshEditor?.activeTool = activeTool
            // Auto Relax is a MODE: a controller installed later must come
            // up in the state the user persisted (task 4.5).
            meshEditor?.autoRelaxEnabled = autoRelaxEnabled
            meshEditor?.onRequestVerb = { [weak self] verb in
                self?.selectVerb(verb)
            }
            // Chip feed (task 3.5): every completed Pencil stroke resolves
            // into a chip — applied, inert, and unrecognized alike.
            meshEditor?.onPencilStrokeResolved = { [weak self] outcome in
                self?.showChip(for: outcome)
            }
            // Camera-as-manipulator sessions (task 4.2): the banner drives
            // the editor's session controls, and the arbiter's camera→tool
            // gate opens exactly while a session is armed.
            meshEditor?.onCameraSessionChanged = { [weak self] banner in
                self?.cameraToolBanner = banner
                self?.controller.setCameraToolSessionArmed(banner != nil)
            }
            meshEditor?.onCameraToolStatus = { [weak self] status in
                self?.cameraToolStatus = status
            }
        }
    }

    // MARK: - Auto Relax + batch commands (task 4.5)

    /// Auto Relax mode (spec: retopology-tools / "Auto Relax"): a persisted
    /// app preference mirrored into the mesh-edit controller, which runs
    /// the redistribution INSIDE each editing operation's own transaction
    /// (one undo step per action, not two).
    private(set) var autoRelaxEnabled: Bool
    /// Where the preference persists (injectable so tests never touch the
    /// user's standard defaults).
    @ObservationIgnored private let defaults: UserDefaults
    /// Presents the batch-commands panel; set by its toolbar action.
    var showsBatchCommands = false

    func setAutoRelax(_ enabled: Bool) {
        guard enabled != autoRelaxEnabled else { return }
        autoRelaxEnabled = enabled
        defaults.set(enabled, forKey: ViewportSettings.autoRelaxKey)
        meshEditor?.autoRelaxEnabled = enabled
    }

    func toggleAutoRelax() {
        setAutoRelax(!autoRelaxEnabled)
    }

    /// Runs one batch command through the journaled path. Returns whether
    /// anything journaled (a no-op stays out of the undo stack).
    @discardableResult
    func runBatchCommand(_ command: BatchCommand) -> Bool {
        meshEditor?.runBatchCommand(command) ?? false
    }

    /// Whether a toggle-style immediate command currently reads as ON (the
    /// toolbar slot tints and reports it).
    func isCommandActive(_ action: EditorAction) -> Bool {
        action == .toggleAutoRelax && autoRelaxEnabled
    }

    init(
        controller: ViewportInputController = ViewportInputController(),
        defaults: UserDefaults = .standard
    ) {
        self.controller = controller
        self.defaults = defaults
        autoRelaxEnabled = defaults.bool(forKey: ViewportSettings.autoRelaxKey)
        controller.capture.consumer = recognizer
        recognizer.onInterpretation = { [weak self] interpretation, _ in
            self?.pendingInterpretation = interpretation
        }
        controller.capture.onStrokeBegan = { [weak self] verb, _, sample in
            // The chip must never block the next stroke: it dismisses the
            // moment new input lands (task 3.5), the hover preview clears
            // the same instant (task 3.6), and so does the quick-verb
            // palette (task 3.7).
            self?.dismissChipForNextStroke()
            self?.dismissPaletteForNextStroke()
            self?.onStrokeWillBegin?()
            self?.meshEditor?.strokeBegan(verb: verb, sample: sample)
        }
        controller.capture.onSampleAppended = { [weak self] sample in
            self?.meshEditor?.strokeContinued(sample: sample)
        }
        controller.capture.onStrokeCancelled = { [weak self] in
            self?.meshEditor?.strokeCancelled()
        }
        controller.capture.onStrokeFinished = { [weak self] stroke in
            self?.publish(stroke)
        }
    }

    /// Replays the committed square gesture fixture through the REAL
    /// capture → recognizer → verb pipeline. UI-test/dev hook (XCUITest
    /// cannot synthesize Pencil touches or a multi-segment single-touch
    /// polyline — and fingers never author, task 3.9 — so the end-to-end
    /// quad-draw UI test injects the stroke here: everything below the raw
    /// UIKit touch layer is the real path; the touch layer itself is
    /// covered by the controller unit suite).
    func injectSquareStroke() {
        inject(fixture: StrokeGestureCorpus.square(type: .finger))
    }

    /// Replays the committed one-stroke-grid fixture through the same real
    /// pipeline (task 3.4 quad-block gesture; same UI-test/dev rationale as
    /// `injectSquareStroke`).
    func injectGridStroke() {
        inject(fixture: StrokeGestureCorpus.grid(type: .finger))
    }

    /// Replays the committed ring-insert line fixture (a vertical line
    /// through the viewport center) through the same real pipeline. Over
    /// the seeded quad this is an AMBIGUOUS stroke — insert loop with a
    /// ranked tag-loop alternative — so the task-3.5 chip UI test can tap
    /// the alternative and assert the journaled swap.
    func injectRingStroke() {
        inject(fixture: StrokeGestureCorpus.ringInsertLine(type: .finger))
    }

    /// Replays any committed fixture through the capture pipeline. The
    /// stroke source mirrors the fixture's recorded touch type (the corpus
    /// was recorded as finger fixtures); injection enters BELOW the touch
    /// layer, so the arbiter's Pencil-only authoring policy is not
    /// bypassed for live input.
    func inject(fixture: StrokeFixture) {
        guard let first = fixture.samples.first else { return }
        let capture = controller.capture
        capture.begin(source: .finger, verb: .pencil, sample: first)
        for sample in fixture.samples.dropFirst() {
            capture.append(sample: sample)
        }
        capture.end()
    }

    /// Stage-2 mesh context for the recognizer, fetched at stroke end so
    /// interpretations always resolve against the CURRENT EditMesh and
    /// camera. The viewport coordinator installs it once the renderer
    /// exists; nil keeps the recognizer in stage-1-only mode.
    func setRecognizerContext(_ provider: StrokeRecognizerConsumer.ContextProvider?) {
        recognizer.contextProvider = provider
    }

    func selectVerb(_ verb: InputArbiter.Verb) {
        disarmTool()
        controller.selectVerb(verb)
        refreshActiveVerb()
    }

    func verbPressBegan(_ verb: InputArbiter.Verb, at time: TimeInterval = CACurrentMediaTime()) {
        controller.verbPressBegan(verb, at: time)
        refreshActiveVerb()
    }

    func verbPressEnded(_ verb: InputArbiter.Verb, at time: TimeInterval = CACurrentMediaTime()) {
        // A quick TAP selects the verb persistently and therefore disarms
        // the tool; releasing a spring-loaded HOLD restores the prior
        // state, tool included (task 4.1).
        if controller.verbPressEnded(verb, at: time) {
            disarmTool()
        }
        refreshActiveVerb()
    }

    // MARK: - Retopology tools (task 4.1)

    /// Arms a build tool: the Pencil verb is selected (tool strokes route
    /// as Pencil) and subsequent Pencil strokes drive the tool. Switching
    /// tools discards any armed camera session (task 4.2).
    func selectTool(_ tool: RetopoTool) {
        if activeTool != tool {
            meshEditor?.cancelCameraToolSession()
        }
        controller.selectVerb(.pencil)
        refreshActiveVerb()
        activeTool = tool
        meshEditor?.activeTool = tool
    }

    // MARK: - Annotations: pins, loop-tag colours, Loop Info (task 4.3)

    /// Palette index new loop tags are authored in (spec: "Users SHALL
    /// color-tag edge loops"). Mirrored into the mesh-edit controller so
    /// the tagLoop grammar and the Pin Flip tool see the same choice.
    private(set) var activeTagColor: UInt8 = MeshAnnotations.defaultTagColor

    func selectTagColor(_ color: UInt8) {
        guard color < MeshAnnotations.tagColorCount else { return }
        activeTagColor = color
        meshEditor?.activeTagColor = color
    }

    /// Loop Info chip content (nil = hidden). Published by the hover
    /// controller when the Pencil holds over an interior edge.
    private(set) var loopInfo: LoopInfoChipState.Info?

    func setLoopInfo(_ info: LoopInfoChipState.Info?) {
        loopInfo = info
    }

    /// Runs an immediate annotation command (the en-masse clears). Returns
    /// whether anything journaled — a no-op clear stays out of the undo
    /// stack entirely.
    @discardableResult
    func runCommand(_ action: EditorAction) -> Bool {
        switch action {
        case .clearPins: return meshEditor?.clearAllPins() ?? false
        case .clearLoopTags: return meshEditor?.clearAllLoopTags() ?? false
        // Task 4.4: symmetry commands. The toggle journals a
        // `setSymmetry`; the two bakes journal one `meshEdit` each.
        case .toggleSymmetry: return meshEditor?.toggleSymmetry() ?? false
        case .applySymmetry: return meshEditor?.applySymmetryNow() ?? false
        // The axis is resolved INSIDE the controller from the document's
        // symmetry state (enabled + an actual mirror axis) — never
        // defaulted to `.x` here, which used to mirror a radial-only or
        // symmetry-off document about an axis the user never enabled.
        case .resymmetrize: return meshEditor?.resymmetrizeNow() ?? false
        // Task 4.5: the Auto Relax MODE toggle is a persisted preference,
        // not a document command — it journals nothing (its effect on the
        // document rides inside the next edit's own entry). The batch panel
        // action just presents the sheet; the commands inside it journal.
        case .toggleAutoRelax:
            toggleAutoRelax()
            return false
        case .batchCommands:
            showsBatchCommands = true
            return false
        default: return false
        }
    }

    private func disarmTool() {
        guard activeTool != nil else { return }
        meshEditor?.cancelCameraToolSession()
        activeTool = nil
        meshEditor?.activeTool = nil
    }

    // MARK: - Camera-as-manipulator session controls (task 4.2)

    /// Banner commit (same path as the Pencil tap on an armed session).
    func commitCameraToolSession() {
        meshEditor?.commitCameraToolSession()
    }

    /// Banner cancel: discards the session, nothing journals.
    func cancelCameraToolSession() {
        meshEditor?.cancelCameraToolSession()
    }

    func setExtendBoundaryMode(_ mode: ExtendBoundaryPlan.Mode) {
        meshEditor?.setExtendBoundaryMode(mode)
    }

    func togglePatchCloneFlip() {
        meshEditor?.togglePatchCloneFlip()
    }

    private func refreshActiveVerb() {
        activeVerb = controller.activeVerb
    }

    /// Publishes the finished stroke: polyline + interpretation record for
    /// the HUD, one log line per interpretation (recognition corpus is
    /// data-driven, design D5 risk mitigation).
    private func publish(_ stroke: ViewportStrokeCapture.CapturedStroke) {
        let interpretation = pendingInterpretation
        pendingInterpretation = nil
        lastInterpretation = interpretation
        lastStrokePolyline = stroke.samples.map { CGPoint(x: $0.x, y: $0.y) }

        // Verb application (tasks 3.3/3.4): commits the brush session, or
        // applies a Pencil interpretation through the gesture grammar —
        // every mutation journaled.
        meshEditor?.strokeEnded(
            verb: stroke.verb, interpretation: interpretation, samples: stroke.samples
        )

        var summary = "Stroke: \(stroke.samples.count) samples "
            + "(\(stroke.source.rawValue), \(stroke.verb.rawValue))"
        if let interpretation, let best = interpretation.best {
            summary += String(
                format: " -> %@ %@ %.2f",
                interpretation.shape.rawValue, best.action.rawValue, best.confidence
            )
        }
        lastStrokeSummary = summary

        if let interpretation {
            let record = interpretation.summary
            Self.log.debug("interpretation: \(record)")
        } else if let error = recognizer.lastError {
            let message = String(describing: error)
            Self.log.error("stroke interpretation failed: \(message)")
        }
    }

    // MARK: - Interpretation chip (task 3.5)

    /// One-tap alternative: swaps the applied result in place through the
    /// journal (`MeshEditController.applyAlternative` → the document's
    /// replace-last path) and re-shows the chip with the swapped outcome.
    /// A failed swap (stale chip) just dismisses.
    func chooseAlternative(_ index: Int) {
        guard let outcome = meshEditor?.applyAlternative(at: index) else {
            chipMachine.dismiss()
            interpretationChip = nil
            return
        }
        showChip(for: outcome)
    }

    private func showChip(for outcome: MeshEditController.PencilStrokeOutcome) {
        chipMachine.strokeResolved(
            interpretation: outcome.interpretation,
            appliedIndex: outcome.appliedIndex,
            alternatives: outcome.alternatives
        )
        interpretationChip = chipMachine.chip
        scheduleChipAutoDismiss(generation: chipMachine.generation)
    }

    private func dismissChipForNextStroke() {
        chipDismissTask?.cancel()
        chipDismissTask = nil
        chipMachine.strokeBegan()
        interpretationChip = nil
    }

    private func scheduleChipAutoDismiss(generation: Int) {
        chipDismissTask?.cancel()
        let delay = chipDismissDelay
        chipDismissTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.autoDismissChip(generation: generation)
        }
    }

    /// Timed dismissal; internal so tests can fire it deterministically.
    /// The generation token makes a stale timer harmless.
    func autoDismissChip(generation: Int) {
        if chipMachine.autoDismiss(generation: generation) {
            interpretationChip = nil
        }
    }

    // MARK: - Pencil Pro quick-verb palette (task 3.7)

    /// A Pencil Pro squeeze completed (`UIPencilInteraction` delegate on
    /// hardware; tests and the UI-test launch hook drive this directly —
    /// the simulator cannot synthesize a squeeze). `location` is the pen
    /// tip's hover position in normalized viewport coordinates, nil when
    /// the pose is unknown (palette falls back to the viewport center).
    func pencilSqueezed(
        action: QuickVerbPaletteState.SqueezeAction, atNormalized location: SIMD2<Float>?
    ) {
        applyPaletteEffects(paletteMachine.squeezeEnded(action: action, at: location))
    }

    /// A palette verb was tapped: select it persistently and dismiss.
    func chooseQuickVerb(_ verb: InputArbiter.Verb) {
        applyPaletteEffects(paletteMachine.verbChosen(verb))
    }

    /// Explicit dismissal (the palette's center close button).
    func dismissQuickVerbPalette() {
        paletteMachine.dismissed()
        quickVerbPalette = nil
    }

    private func dismissPaletteForNextStroke() {
        paletteMachine.strokeBegan()
        quickVerbPalette = nil
    }

    private func applyPaletteEffects(_ effects: [QuickVerbPaletteState.Effect]) {
        for effect in effects {
            switch effect {
            case .selectVerb(let verb):
                selectVerb(verb)
            }
        }
        quickVerbPalette = paletteMachine.palette
    }

    // MARK: - Pencil Pro barrel roll (task 3.7)

    /// Roll-angle update from the viewport's hover recognizer. Dedupes so
    /// pointer hardware that always reports 0 never spams observation.
    /// Consumed by the armed camera-as-manipulator session (task 3.7a/4.2:
    /// barrel roll rotates the element being placed).
    func barrelRollChanged(_ angle: Float) {
        guard angle != barrelRollAngle else { return }
        barrelRollAngle = angle
        meshEditor?.barrelRollChanged(angle)
        onBarrelRollChanged?(angle)
    }
}

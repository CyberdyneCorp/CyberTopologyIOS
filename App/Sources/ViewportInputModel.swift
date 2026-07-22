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
    /// reports it. Rotate-placed-element hook: `onBarrelRollChanged` is
    /// the seam a placement tool subscribes to; no task-3.4 op has a free
    /// orientation (quads/grids take theirs from the drawn stroke), so the
    /// first real consumer is the 4.2 placement tools (tasks.md 3.7a).
    private(set) var barrelRollAngle: Float = 0
    @ObservationIgnored var onBarrelRollChanged: ((Float) -> Void)?

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
            meshEditor?.onRequestVerb = { [weak self] verb in
                self?.selectVerb(verb)
            }
            // Chip feed (task 3.5): every completed Pencil stroke resolves
            // into a chip — applied, inert, and unrecognized alike.
            meshEditor?.onPencilStrokeResolved = { [weak self] outcome in
                self?.showChip(for: outcome)
            }
        }
    }

    init(controller: ViewportInputController = ViewportInputController()) {
        self.controller = controller
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
        controller.selectVerb(verb)
        refreshActiveVerb()
    }

    func verbPressBegan(_ verb: InputArbiter.Verb, at time: TimeInterval = CACurrentMediaTime()) {
        controller.verbPressBegan(verb, at: time)
        refreshActiveVerb()
    }

    func verbPressEnded(_ verb: InputArbiter.Verb, at time: TimeInterval = CACurrentMediaTime()) {
        controller.verbPressEnded(verb, at: time)
        refreshActiveVerb()
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
    func barrelRollChanged(_ angle: Float) {
        guard angle != barrelRollAngle else { return }
        barrelRollAngle = angle
        onBarrelRollChanged?(angle)
    }
}

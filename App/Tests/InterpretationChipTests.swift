import CyberKit
import Testing
@testable import CyberTopology

/// Task 3.5: the post-stroke interpretation chip's SHOW / REPLACE /
/// DISMISS state machine (spec: pencil-interaction / "Post-stroke
/// interpretation chip") plus the model-level wiring — chip published on
/// stroke resolution, dismissed the moment the next stroke begins, and
/// auto-dismissed with a stale-timer-proof generation token.
struct InterpretationChipStateTests {
    // Under the curated grammar the only genuinely ambiguous stroke carries
    // kept actions only: a closed outline whose corner estimate sits between
    // four and three corners ranks createQuad over createTriangle. (The state
    // machine itself is action-agnostic — this fixture just keeps the two-
    // candidate path exercised without referencing a retired gesture.)
    private let ambiguous = StrokeInterpretation(
        shape: .closedLoop, shapeConfidence: 0.99, context: .face,
        candidates: [
            .init(action: .createQuad, confidence: 0.74, elements: [
                .init(kind: .face, id: 1),
            ]),
            .init(action: .createTriangle, confidence: 0.35, elements: [
                .init(kind: .face, id: 1),
            ]),
        ]
    )

    @Test func showPublishesTitleConfidenceAndAlternatives() {
        var machine = InterpretationChipState()
        #expect(machine.chip == nil)

        machine.strokeResolved(
            interpretation: ambiguous, appliedIndex: 0, alternatives: [1]
        )
        let chip = machine.chip
        #expect(chip?.title == "Quad")
        #expect(chip?.detail == "74%")
        #expect(chip?.alternatives.count == 1)
        #expect(chip?.alternatives.first?.id == 1)
        #expect(chip?.alternatives.first?.action == .createTriangle)
        #expect(chip?.alternatives.first?.label == "Triangle")
    }

    @Test func replaceAfterSwapShowsTheSwappedResultWithSwapBack() {
        var machine = InterpretationChipState()
        machine.strokeResolved(
            interpretation: ambiguous, appliedIndex: 0, alternatives: [1]
        )
        let first = machine.chip?.generation

        // After the swap the chip re-shows the applied alternative and
        // offers the original back — under a NEW dismiss generation.
        machine.strokeResolved(
            interpretation: ambiguous, appliedIndex: 1, alternatives: [0]
        )
        let chip = machine.chip
        #expect(chip?.title == "Triangle")
        #expect(chip?.detail == "35%")
        #expect(chip?.alternatives.first?.action == .createQuad)
        #expect(chip?.generation != first)
    }

    @Test func rejectedAndInertStrokesShowInformationalChips() {
        var machine = InterpretationChipState()

        // Recognition failed entirely.
        machine.strokeResolved(interpretation: nil, appliedIndex: nil, alternatives: [])
        #expect(machine.chip?.title == "Not recognized")
        #expect(machine.chip?.detail == nil)
        #expect(machine.chip?.alternatives.isEmpty == true)

        // Recognized but nothing applied (e.g. a line over empty surface with
        // no quad ring to cut): the chip says what matched and that nothing
        // changed.
        let inert = StrokeInterpretation(
            shape: .line, shapeConfidence: 0.9, context: .emptySurface,
            candidates: [.init(action: .insertLoop, confidence: 0.5, elements: [])]
        )
        machine.strokeResolved(interpretation: inert, appliedIndex: nil, alternatives: [])
        #expect(machine.chip?.title == "Insert loop — no change")
        #expect(machine.chip?.detail == "50%")

        // A best-of-nothing record reads as unrecognized.
        let none = StrokeInterpretation(
            shape: .scribble, shapeConfidence: 0.7, context: .emptySurface,
            candidates: [.init(action: .none, confidence: 0, elements: [])]
        )
        machine.strokeResolved(interpretation: none, appliedIndex: nil, alternatives: [])
        #expect(machine.chip?.title == "Not recognized")
    }

    @Test func nextStrokeWhileVisibleDismissesImmediately() {
        var machine = InterpretationChipState()
        machine.strokeResolved(
            interpretation: ambiguous, appliedIndex: 0, alternatives: [1]
        )
        #expect(machine.chip != nil)
        machine.strokeBegan()
        #expect(machine.chip == nil)
    }

    @Test func autoDismissOnlyFiresForItsOwnGeneration() {
        var machine = InterpretationChipState()
        machine.strokeResolved(
            interpretation: ambiguous, appliedIndex: 0, alternatives: [1]
        )
        let stale = machine.generation
        // A newer chip supersedes the timer's target…
        machine.strokeResolved(
            interpretation: ambiguous, appliedIndex: 1, alternatives: [0]
        )
        let staleFired = machine.autoDismiss(generation: stale)
        #expect(!staleFired)
        #expect(machine.chip != nil)
        // …and the matching generation dismisses exactly once.
        let fired = machine.autoDismiss(generation: machine.generation)
        #expect(fired)
        #expect(machine.chip == nil)
        let repeated = machine.autoDismiss(generation: machine.generation)
        #expect(!repeated)
    }

    @Test func alternativeIndicesOutOfRangeAreDroppedNotTrapped() {
        var machine = InterpretationChipState()
        machine.strokeResolved(
            interpretation: ambiguous, appliedIndex: 0, alternatives: [1, 7]
        )
        #expect(machine.chip?.alternatives.map(\.id) == [1])
    }

    @Test func everyActionHasAChipLabel() {
        for action in StrokeInterpretation.Action.allCases {
            #expect(!InterpretationChipState.label(for: action).isEmpty)
        }
    }
}

/// Model-level chip wiring: `ViewportInputModel` publishes the chip for the
/// editor overlay, dismisses it on the next stroke, and auto-dismisses via
/// the generation token (stale timers are harmless).
@MainActor
struct InterpretationChipModelTests {
    /// Resolves a Pencil stroke through the REAL capture → recognizer →
    /// controller path (no mesh context installed: the square classifies
    /// and resolves as an inert createQuad — chip-visible either way).
    private func resolveStroke(on model: ViewportInputModel) {
        model.meshEditor = MeshEditController()
        model.injectSquareStroke()
    }

    @Test func resolvedStrokePublishesAChip() {
        let model = ViewportInputModel()
        #expect(model.interpretationChip == nil)
        resolveStroke(on: model)
        let chip = model.interpretationChip
        #expect(chip != nil)
        // No context provider → recognized but nothing applied.
        #expect(chip?.title == "Quad — no change")
    }

    @Test func nextStrokeBeginningDismissesTheChip() {
        let model = ViewportInputModel()
        resolveStroke(on: model)
        #expect(model.interpretationChip != nil)

        // The next stroke's FIRST sample dismisses the chip — before the
        // stroke even completes (never blocks the next stroke).
        model.controller.capture.begin(
            source: .finger, verb: .pencil,
            sample: .init(time: 0, x: 0.2, y: 0.2, type: .finger)
        )
        #expect(model.interpretationChip == nil)
        model.controller.capture.cancel()
    }

    @Test func autoDismissHidesOwnGenerationOnly() {
        let model = ViewportInputModel()
        resolveStroke(on: model)
        let first = model.interpretationChip?.generation ?? -1

        // A stale timer (older generation) never hides a newer chip.
        resolveStroke(on: model)
        let second = model.interpretationChip?.generation ?? -1
        #expect(second != first)
        model.autoDismissChip(generation: first)
        #expect(model.interpretationChip != nil)

        model.autoDismissChip(generation: second)
        #expect(model.interpretationChip == nil)
    }

    @Test func autoDismissTimerHidesTheChip() async throws {
        let model = ViewportInputModel()
        model.chipDismissDelay = .milliseconds(20)
        resolveStroke(on: model)
        #expect(model.interpretationChip != nil)

        // The scheduled dismissal fires on its own.
        for _ in 0..<100 where model.interpretationChip != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.interpretationChip == nil)
    }

    @Test func chooseAlternativeWithoutSwapContextDismisses() {
        let model = ViewportInputModel()
        resolveStroke(on: model)
        #expect(model.interpretationChip != nil)
        // Nothing applied → no swap context → the tap dismisses instead of
        // crashing or journaling anything.
        model.chooseAlternative(1)
        #expect(model.interpretationChip == nil)
    }
}

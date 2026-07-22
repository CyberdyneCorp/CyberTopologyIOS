import CoreHaptics
import Testing
import UIKit
@testable import CyberTopology

/// Task 3.7 (spec: pencil-interaction / "Pencil Pro and haptic feedback",
/// scenario "Snap feedback"): the PURE event → feedback mapping, unit-tested
/// headless exactly like the arbiter — events (drag candidate updates,
/// stroke end/cancel) in, highlight/tick effects out — plus the
/// capability-gating of the production haptics engine (simulator: graceful
/// no-op; actual actuation is device-only, see `PencilProHardwareTests`).
struct SnapFeedbackTests {
    private let targetA = HoverPreviewState.SnapTarget(
        vertex: 7, position: SIMD3(1, 0, 0)
    )
    private let targetB = HoverPreviewState.SnapTarget(
        vertex: 9, position: SIMD3(0, 1, 0)
    )

    // MARK: - Event → feedback mapping (highlight BEFORE commit)

    @Test func enteringMergeRangeHighlightsAndTicksOnce() {
        var state = SnapFeedbackState()
        #expect(state.dragUpdated(candidate: targetA) == [
            .showHighlight(targetA), .tick(.snapEngaged),
        ])
        #expect(state.candidate == targetA)
        // Staying inside the same target's range emits nothing new.
        #expect(state.dragUpdated(candidate: targetA) == [])
    }

    @Test func movingBetweenTargetsRehighlightsAndReticks() {
        var state = SnapFeedbackState()
        _ = state.dragUpdated(candidate: targetA)
        #expect(state.dragUpdated(candidate: targetB) == [
            .showHighlight(targetB), .tick(.snapEngaged),
        ])
    }

    @Test func leavingMergeRangeClearsTheHighlightSilently() {
        var state = SnapFeedbackState()
        _ = state.dragUpdated(candidate: targetA)
        #expect(state.dragUpdated(candidate: nil) == [.clearHighlight])
        #expect(state.candidate == nil)
        // No candidate → nothing to clear.
        #expect(state.dragUpdated(candidate: nil) == [])
    }

    // MARK: - Tick ON commit

    @Test func committedMergeClearsHighlightAndTicks() {
        var state = SnapFeedbackState()
        _ = state.dragUpdated(candidate: targetA)
        #expect(state.strokeEnded(committed: true) == [
            .clearHighlight, .tick(.commit),
        ])
        #expect(state.candidate == nil)
    }

    @Test func uncommittedStrokeEndNeverTicks() {
        var state = SnapFeedbackState()
        _ = state.dragUpdated(candidate: targetA)
        // The stroke ended outside merge range / the command never reached
        // the journal: highlight clears, no commit tick.
        #expect(state.strokeEnded(committed: false) == [.clearHighlight])
    }

    @Test func cancelledStrokeClearsWithoutAnyTick() {
        var state = SnapFeedbackState()
        _ = state.dragUpdated(candidate: targetA)
        #expect(state.strokeCancelled() == [.clearHighlight])
        var idle = SnapFeedbackState()
        #expect(idle.strokeCancelled() == [])
    }

    // MARK: - User-disableable haptics (highlight stays, ticks go)

    @Test func disabledHapticsDropTicksButKeepTheHighlight() {
        var state = SnapFeedbackState()
        state.hapticsEnabled = false
        #expect(state.dragUpdated(candidate: targetA) == [.showHighlight(targetA)])
        #expect(state.strokeEnded(committed: true) == [.clearHighlight])
    }

    // MARK: - Production engine capability gating (simulator: no-op)

    @MainActor
    @Test func hapticsEngineIsAGracefulNoOpWithoutHapticHardware() {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let engine = SnapHapticsEngine(view: view)
        // The simulator reports no Taptic Engine; the play calls below must
        // not crash and must not lazily spin up Core Haptics.
        if !CHHapticEngine.capabilitiesForHardware().supportsHaptics {
            #expect(engine.supportsCoreHaptics == false)
        }
        engine.play(.snapEngaged, atNormalized: CGPoint(x: 0.5, y: 0.5))
        engine.play(.commit, atNormalized: nil)
    }
}

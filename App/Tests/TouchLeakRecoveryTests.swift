import Testing
@testable import CyberTopology

/// Losing finger navigation permanently (openspec fix-lost-finger-navigation).
///
/// REPORTED FROM DEVICE: "sometimes we lose the navigation (rotation, zoom, pan)
/// with the fingers on the viewport. All the rest — the buttons, the toolbar,
/// even the pen — works."
///
/// That asymmetry names the mechanism. Camera recognizers are gated by
/// `InputArbiter.allowsCameraTouch`, which refuses a finger once two are already
/// tracked; the pen is gated only by `penStrokeTouch`, and the toolbar buttons
/// are SwiftUI outside the viewport entirely. So a tracked finger that is never
/// released blocks navigation and nothing else — permanently, because entries
/// leave `touches` ONLY via `touchEnded`/`touchCancelled`.
@MainActor
struct TouchLeakRecoveryTests {
    /// The stuck state itself: two fingers whose end never arrives.
    @Test func twoUnreleasedFingersBlockEveryFurtherCameraTouch() {
        var arbiter = InputArbiter()
        _ = arbiter.touchBegan(1, kind: .finger)
        _ = arbiter.touchBegan(2, kind: .finger)

        // A third finger is correctly refused while two are genuinely down…
        #expect(!arbiter.allowsCameraTouch(kind: .finger))
        // …but if their ends are never delivered, the refusal is forever: the
        // arbiter has no other path that removes them.
        #expect(arbiter.activeTouchCount == 2)
        #expect(!arbiter.allowsCameraTouch(kind: .finger))
        // The pen is unaffected — which is exactly what the report describes.
        #expect(arbiter.allowsCameraTouch(kind: .pencil) == false)  // pen never drives camera
        #expect(!arbiter.isPenDown, "no pen is down; only fingers leaked")
    }

    /// The recovery: UIKit calls `reset()` on a recognizer when its touch
    /// sequence finishes, so that is the moment to reconcile. Anything still
    /// tracked then was never released and must be dropped.
    @Test func endingTheSequenceReleasesLeakedTouches() {
        var arbiter = InputArbiter()
        _ = arbiter.touchBegan(1, kind: .finger)
        _ = arbiter.touchBegan(2, kind: .finger)
        #expect(!arbiter.allowsCameraTouch(kind: .finger))

        arbiter.allTouchesFinished()

        #expect(arbiter.activeTouchCount == 0)
        #expect(arbiter.allowsCameraTouch(kind: .finger), "navigation must come back")
    }

    /// A leaked PEN touch is the same failure with a different symptom: while
    /// `penStrokeTouch` is set, palm rejection refuses every finger.
    @Test func aLeakedPenTouchAlsoRecovers() {
        var arbiter = InputArbiter()
        _ = arbiter.touchBegan(1, kind: .pencil)
        #expect(arbiter.isPenDown)
        #expect(!arbiter.allowsCameraTouch(kind: .finger), "palm rejection while the pen is down")

        arbiter.allTouchesFinished()

        #expect(!arbiter.isPenDown)
        #expect(arbiter.allowsCameraTouch(kind: .finger))
    }

    /// Reconciling must CANCEL an authoring stroke rather than leave the
    /// capture half-open: the stroke's touch is gone, so no end can ever come.
    @Test func reconcilingCancelsAnAuthoringStroke() {
        var arbiter = InputArbiter()
        _ = arbiter.touchBegan(1, kind: .pencil)

        let decisions = arbiter.allTouchesFinished()

        #expect(decisions.contains { if case .cancelStroke = $0 { return true } else { return false } })
    }

    /// Reconciling an already-clean arbiter does nothing — `reset()` runs at the
    /// end of every ordinary gesture, so it must be free of side effects.
    @Test func reconcilingWhenNothingIsTrackedIsANoOp() {
        var arbiter = InputArbiter()
        #expect(arbiter.allTouchesFinished().isEmpty)
        #expect(arbiter.activeTouchCount == 0)
        #expect(arbiter.allowsCameraTouch(kind: .finger))
    }

    /// `forget` is the recovery that actually runs in practice: `reset()` only
    /// fires once a recognizer leaves `.possible`, and the observer never
    /// changes state — so the sweep driven by `UITouch.phase` is what heals a
    /// leak while OTHER touches are still live.
    @Test func forgettingADeadTouchRestoresNavigation() {
        var arbiter = InputArbiter()
        _ = arbiter.touchBegan(1, kind: .finger)
        _ = arbiter.touchBegan(2, kind: .finger)
        #expect(!arbiter.allowsCameraTouch(kind: .finger))

        // One of them is discovered dead (UIKit already ended it).
        _ = arbiter.forget([1])

        #expect(arbiter.activeTouchCount == 1)
        #expect(arbiter.allowsCameraTouch(kind: .finger), "one live finger still admits a second")
    }

    @Test func forgettingCancelsAnAuthoringStrokeAndClearsThePen() {
        var arbiter = InputArbiter()
        _ = arbiter.touchBegan(1, kind: .pencil)
        #expect(arbiter.isPenDown)

        let decisions = arbiter.forget([1])

        #expect(decisions.contains { if case .cancelStroke = $0 { return true } else { return false } })
        #expect(!arbiter.isPenDown, "a dead pen touch must not keep palm rejection armed")
        #expect(arbiter.allowsCameraTouch(kind: .finger))
    }

    @Test func forgettingAnUnknownIdIsHarmless() {
        var arbiter = InputArbiter()
        _ = arbiter.touchBegan(1, kind: .finger)
        #expect(arbiter.forget([99]).isEmpty)
        #expect(arbiter.activeTouchCount == 1)
    }

    /// The controller layer forwards it, and clears its own touch→id map: a
    /// stale entry there would hand a NEW touch the id of a dead one, since
    /// UIKit recycles `UITouch` objects.
    @Test func theControllerClearsItsIdMapToo() {
        let controller = ViewportInputController()
        controller.allTouchesFinished()
        #expect(controller.arbiter.activeTouchCount == 0)
        #expect(controller.arbiter.allowsCameraTouch(kind: .finger))
    }
}

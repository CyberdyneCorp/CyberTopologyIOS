import Foundation
import Testing
@testable import CyberTopology

/// Exhaustive transition tests for the pure touch/Pencil arbitration state
/// machine (task 3.1, design D5; spec: pencil-interaction / "Input division
/// of labor" + "Hold-chord spring-loaded modifiers").
struct InputArbiterTests {
    private typealias Decision = InputArbiter.Decision

    // MARK: - Pencil authoring lifecycle

    @Test func penStrokeLifecycleAuthors() {
        var arbiter = InputArbiter()
        #expect(arbiter.touchBegan(1, kind: .pencil)
            == [.beginStroke(1, source: .pencil, verb: .pencil)])
        #expect(arbiter.isPenDown)
        #expect(arbiter.touchMoved(1) == [.appendToStroke(1)])
        #expect(arbiter.touchEnded(1) == [.endStroke(1)])
        #expect(!arbiter.isPenDown)
        #expect(arbiter.activeTouchCount == 0)
    }

    @Test func penCancellationCancelsStroke() {
        var arbiter = InputArbiter()
        _ = arbiter.touchBegan(1, kind: .pencil)
        #expect(arbiter.touchCancelled(1) == [.cancelStroke(1)])
        #expect(!arbiter.isPenDown)
    }

    @Test func secondPencilContactIsRejected() {
        var arbiter = InputArbiter()
        _ = arbiter.touchBegan(1, kind: .pencil)
        #expect(arbiter.touchBegan(2, kind: .pencil) == [.rejectTouch(2)])
        // The stray contact never authors, and its lift is silent.
        #expect(arbiter.touchMoved(2) == [])
        #expect(arbiter.touchEnded(2) == [])
        // The real stroke is unaffected.
        #expect(arbiter.touchMoved(1) == [.appendToStroke(1)])
    }

    @Test func duplicateAndUnknownTouchEventsAreIgnored() {
        var arbiter = InputArbiter()
        _ = arbiter.touchBegan(1, kind: .pencil)
        #expect(arbiter.touchBegan(1, kind: .pencil) == [])
        #expect(arbiter.touchMoved(99) == [])
        #expect(arbiter.touchEnded(99) == [])
        #expect(arbiter.touchCancelled(99) == [])
    }

    // MARK: - Palm rejection (spec scenario "Palm rejection during pen stroke")

    @Test func palmTouchesWhilePenIsDownAreRejected() {
        var arbiter = InputArbiter()
        _ = arbiter.touchBegan(1, kind: .pencil)

        // The rejection also resets the camera/undo recognizers: a palm
        // delivered in the SAME event batch as the pen-down passes the
        // `shouldReceive` gate before the arbiter knows the pen is down,
        // and only this decision can evict it afterwards.
        #expect(arbiter.touchBegan(2, kind: .finger)
            == [.rejectTouch(2), .cancelCameraGestures])
        // The palm can neither steer the camera nor fire undo taps…
        #expect(!arbiter.allowsCameraTouch(kind: .finger))
        #expect(!arbiter.allowsUndoTap(kind: .finger))
        // …nor author, even while it moves.
        #expect(arbiter.touchMoved(2) == [])
        #expect(arbiter.touchEnded(2) == [])
    }

    @Test func threeFingersDuringPenStrokeAreAllRejected() {
        var arbiter = InputArbiter()
        _ = arbiter.touchBegan(1, kind: .pencil)
        #expect(arbiter.touchBegan(2, kind: .finger)
            == [.rejectTouch(2), .cancelCameraGestures])
        #expect(arbiter.touchBegan(3, kind: .finger)
            == [.rejectTouch(3), .cancelCameraGestures])
        #expect(arbiter.touchBegan(4, kind: .finger)
            == [.rejectTouch(4), .cancelCameraGestures])
        // No camera, no undo/redo: nothing fires from the finger chord.
        #expect(!arbiter.allowsCameraTouch(kind: .finger))
        #expect(!arbiter.allowsUndoTap(kind: .finger))
        // Pen keeps authoring through all of it.
        #expect(arbiter.touchMoved(1) == [.appendToStroke(1)])
    }

    @Test func palmStaysRejectedAfterPenLifts() {
        var arbiter = InputArbiter()
        _ = arbiter.touchBegan(1, kind: .pencil)
        _ = arbiter.touchBegan(2, kind: .finger)
        _ = arbiter.touchEnded(1)

        // The palm that landed during the stroke never becomes an actor…
        #expect(arbiter.touchMoved(2) == [])
        #expect(arbiter.touchEnded(2) == [])
        // …but new finger touches after the pen lifted are normal again.
        var after = arbiter
        #expect(after.allowsCameraTouch(kind: .finger))
        #expect(after.allowsUndoTap(kind: .finger))
        #expect(after.touchBegan(3, kind: .finger) == [])
    }

    /// Regression: a palm (two rejected contact patches) resting through
    /// the pen lift must not consume the two-finger camera budget —
    /// rejected touches are inert, so they never count as fingers.
    @Test func restingPalmAfterPenLiftDoesNotConsumeTheFingerBudget() {
        var arbiter = InputArbiter()
        _ = arbiter.touchBegan(1, kind: .pencil)
        #expect(arbiter.touchBegan(2, kind: .finger)
            == [.rejectTouch(2), .cancelCameraGestures])
        #expect(arbiter.touchBegan(3, kind: .finger)
            == [.rejectTouch(3), .cancelCameraGestures])
        _ = arbiter.touchEnded(1)  // pen lifts, palm keeps resting

        // The rejected palm counts zero fingers: a deliberate two-finger
        // pinch/pan is admitted finger by finger…
        #expect(arbiter.fingerCount() == 0)
        #expect(arbiter.allowsCameraTouch(kind: .finger, excluding: 4))
        _ = arbiter.touchBegan(4, kind: .finger)
        #expect(arbiter.allowsCameraTouch(kind: .finger, excluding: 5))
        _ = arbiter.touchBegan(5, kind: .finger)
        // …and with two REAL camera fingers down the third is still denied.
        #expect(!arbiter.allowsCameraTouch(kind: .finger, excluding: 6))
    }

    // MARK: - Pen priority

    @Test func penCancelsCameraGesturesInFlight() {
        var arbiter = InputArbiter()
        #expect(arbiter.touchBegan(1, kind: .finger) == [])
        #expect(arbiter.touchBegan(2, kind: .finger) == [])

        let decisions = arbiter.touchBegan(3, kind: .pencil)
        #expect(decisions == [
            .cancelCameraGestures, .beginStroke(3, source: .pencil, verb: .pencil),
        ])
        // The demoted camera fingers stay inert even after the pen lifts.
        _ = arbiter.touchEnded(3)
        #expect(arbiter.touchMoved(1) == [])
        #expect(arbiter.touchEnded(1) == [])
        #expect(arbiter.touchEnded(2) == [])
    }

    // MARK: - Fingers never author (spec scenario "Finger strokes never author")

    @Test func fingerNavigatesByDefault() {
        var arbiter = InputArbiter()
        #expect(arbiter.touchBegan(1, kind: .finger) == [])
        #expect(arbiter.touchMoved(1) == [])
        #expect(arbiter.touchEnded(1) == [])
        #expect(arbiter.allowsCameraTouch(kind: .finger))
    }

    /// Spec scenario "Finger strokes never author": a finger tracing a
    /// quad-shaped path (many moves, like a square gesture would produce)
    /// yields NO authoring decision at any point — the touch stays
    /// camera-owned for its whole lifetime, so the orbit recognizer (which
    /// the camera gate keeps admitting) drives the camera instead.
    @Test func fingerQuadShapedStrokeNeverAuthorsAndStaysWithTheCamera() {
        var arbiter = InputArbiter()
        // The camera gate admits the finger before it lands…
        #expect(arbiter.allowsCameraTouch(kind: .finger, excluding: 1))
        #expect(arbiter.touchBegan(1, kind: .finger) == [])
        // …and every corner of the square emits no stroke decision.
        for _ in 0..<8 {
            #expect(arbiter.touchMoved(1) == [])
        }
        #expect(!arbiter.isPenDown)
        #expect(arbiter.allowsCameraTouch(kind: .finger))  // still navigating
        #expect(arbiter.touchEnded(1) == [])  // no endStroke either
        #expect(arbiter.activeTouchCount == 0)
    }

    /// The policy holds under every verb: even with a verb spring-loaded
    /// or persistently selected, a finger down never begins a stroke.
    @Test func fingerNeverAuthorsRegardlessOfActiveVerb() {
        var arbiter = InputArbiter()
        arbiter.selectVerb(.relax)
        #expect(arbiter.touchBegan(1, kind: .finger) == [])
        _ = arbiter.touchEnded(1)
        arbiter.verbPressBegan(.erase, at: 0)  // spring-loaded hold
        #expect(arbiter.touchBegan(2, kind: .finger) == [])
        #expect(arbiter.touchMoved(2) == [])
        #expect(arbiter.touchEnded(2) == [])
    }

    // MARK: - Camera gating (>2 touches never cause erratic camera motion)

    @Test func thirdFingerIsNeverAdmittedToCameraGestures() {
        var arbiter = InputArbiter()
        _ = arbiter.touchBegan(1, kind: .finger)
        _ = arbiter.touchBegan(2, kind: .finger)
        // Two fingers already down: a 3rd is denied at the camera gate.
        #expect(!arbiter.allowsCameraTouch(kind: .finger, excluding: 3))
        // Undo taps stay available (the 3-finger undo tap needs them).
        #expect(arbiter.allowsUndoTap(kind: .finger))
    }

    @Test func excludingTheAskedTouchKeepsGatingOrderIndependent() {
        var arbiter = InputArbiter()
        _ = arbiter.touchBegan(1, kind: .finger)
        _ = arbiter.touchBegan(2, kind: .finger)
        // Touch 2 already registered by the observer: asking about touch 2
        // itself must not count it against the two-finger limit.
        #expect(arbiter.allowsCameraTouch(kind: .finger, excluding: 2))
        #expect(arbiter.fingerCount() == 2)
        #expect(arbiter.fingerCount(excluding: 2) == 1)
    }

    @Test func pencilNeverDrivesCameraOrUndo() {
        let arbiter = InputArbiter()
        #expect(!arbiter.allowsCameraTouch(kind: .pencil))
        #expect(!arbiter.allowsUndoTap(kind: .pencil))
    }

    // MARK: - Hold-chord spring-loaded verbs (spec scenario "Spring-loaded Relax")

    @Test func quickTapSelectsVerbPersistently() {
        var arbiter = InputArbiter()
        arbiter.verbPressBegan(.relax, at: 0)
        arbiter.verbPressEnded(.relax, at: 0.1)  // < tapSelectThreshold
        #expect(arbiter.activeVerb == .relax)
        #expect(arbiter.persistentVerb == .relax)
    }

    @Test func springLoadedHoldActivatesVerbForHoldDurationOnly() {
        var arbiter = InputArbiter()
        arbiter.selectVerb(.move)

        arbiter.verbPressBegan(.relax, at: 0)
        #expect(arbiter.activeVerb == .relax)  // active for the hold…
        arbiter.verbPressEnded(.relax, at: 1.2)  // ≥ tapSelectThreshold
        #expect(arbiter.activeVerb == .move)  // …prior tool restored
        #expect(arbiter.persistentVerb == .move)
    }

    @Test func strokeBegunDuringHoldCarriesTheHeldVerb() {
        var arbiter = InputArbiter()
        arbiter.verbPressBegan(.erase, at: 0)
        #expect(arbiter.touchBegan(1, kind: .pencil)
            == [.beginStroke(1, source: .pencil, verb: .erase)])
    }

    @Test func penLiftMidChordKeepsTheHeldVerbUntilRelease() {
        var arbiter = InputArbiter()
        arbiter.verbPressBegan(.relax, at: 0)

        // First stroke under the hold.
        _ = arbiter.touchBegan(1, kind: .pencil)
        #expect(arbiter.touchEnded(1) == [.endStroke(1)])  // pen lifts mid-chord

        // The chord is still held: the next stroke also uses Relax.
        #expect(arbiter.touchBegan(2, kind: .pencil)
            == [.beginStroke(2, source: .pencil, verb: .relax)])
        _ = arbiter.touchEnded(2)

        // Releasing the (long) hold restores the prior tool immediately.
        arbiter.verbPressEnded(.relax, at: 2.0)
        #expect(arbiter.activeVerb == .pencil)
    }

    /// Regression: releasing the CURRENT hold while an older button is
    /// still physically down must fall back to that still-held verb —
    /// not silently drop to the persistent tool mid-chord.
    @Test func releasingTheCurrentHoldRestoresAnOlderStillHeldOne() {
        var arbiter = InputArbiter()
        arbiter.verbPressBegan(.relax, at: 0)
        arbiter.verbPressBegan(.erase, at: 0.1)  // second button joins
        #expect(arbiter.activeVerb == .erase)

        // Erase released as a LONG hold (no persistent select) while the
        // Relax finger never lifted: Relax applies again immediately.
        arbiter.verbPressEnded(.erase, at: 0.6)
        #expect(arbiter.activeVerb == .relax)
        #expect(arbiter.persistentVerb == .pencil)
        // A stroke started now carries the restored hold.
        #expect(arbiter.touchBegan(1, kind: .pencil)
            == [.beginStroke(1, source: .pencil, verb: .relax)])
        _ = arbiter.touchEnded(1)

        // Releasing the last held button restores the persistent tool.
        arbiter.verbPressEnded(.relax, at: 1.5)
        #expect(arbiter.activeVerb == .pencil)
    }

    @Test func releasingAStaleHoldDoesNotClobberANewerOne() {
        var arbiter = InputArbiter()
        arbiter.verbPressBegan(.relax, at: 0)
        arbiter.verbPressBegan(.erase, at: 0.1)  // second button joins
        #expect(arbiter.activeVerb == .erase)
        arbiter.verbPressEnded(.relax, at: 1.0)  // stale release
        #expect(arbiter.activeVerb == .erase)  // newest hold still wins
        arbiter.verbPressEnded(.erase, at: 1.5)
        #expect(arbiter.activeVerb == .pencil)
    }

    @Test func selectVerbChangesThePersistentTool() {
        var arbiter = InputArbiter()
        arbiter.selectVerb(.tweak)
        #expect(arbiter.activeVerb == .tweak)
        #expect(arbiter.touchBegan(1, kind: .pencil)
            == [.beginStroke(1, source: .pencil, verb: .tweak)])
    }

    @Test func verbPressEndedReportsTapSelectionOnly() {
        // Task 4.1: the tool layer disarms exactly on TAP-selection —
        // spring-loaded holds must report false so a hold cannot kick the
        // user out of an armed tool.
        var arbiter = InputArbiter()
        arbiter.verbPressBegan(.relax, at: 0)
        #expect(arbiter.verbPressEnded(.relax, at: 0.1) == true)  // quick tap
        arbiter.verbPressBegan(.erase, at: 1)
        #expect(arbiter.verbPressEnded(.erase, at: 2) == false)  // hold
        #expect(arbiter.activeVerb == .relax)  // tap selected, hold restored
    }

    // MARK: - Camera-as-manipulator routing (task 4.2)

    @Test func cameraFeedsArmedToolExactlyWhileASessionIsArmed() {
        // The camera→tool verdict lives in the arbiter (design D5): open
        // only between arm and disarm.
        var arbiter = InputArbiter()
        #expect(!arbiter.cameraFeedsArmedTool)
        arbiter.setCameraToolSessionArmed(true)
        #expect(arbiter.cameraFeedsArmedTool)
        arbiter.setCameraToolSessionArmed(false)
        #expect(!arbiter.cameraFeedsArmedTool)
    }

    @Test func penDownClosesTheCameraToolFeed() {
        // While the pen is down camera gestures are palm-rejected anyway;
        // the tool feed must be closed too so a stray demoted touch can
        // never steer a placement mid-stroke.
        var arbiter = InputArbiter()
        arbiter.setCameraToolSessionArmed(true)
        _ = arbiter.touchBegan(1, kind: .pencil)
        #expect(arbiter.isPenDown)
        #expect(!arbiter.cameraFeedsArmedTool)
        _ = arbiter.touchEnded(1)
        #expect(arbiter.cameraFeedsArmedTool)
    }

    @Test func armedCameraSessionKeepsNavigationInvariantsIntact() {
        // Arming the camera-as-manipulator mode must not loosen ANY of
        // the pen-authors/fingers-navigate rules: fingers still navigate,
        // palms still reject, the 3rd finger stays out.
        var arbiter = InputArbiter()
        arbiter.setCameraToolSessionArmed(true)
        #expect(arbiter.touchBegan(1, kind: .finger) == [])
        #expect(arbiter.allowsCameraTouch(kind: .finger, excluding: 1))
        _ = arbiter.touchBegan(2, kind: .finger)
        #expect(!arbiter.allowsCameraTouch(kind: .finger))  // 3rd finger
        _ = arbiter.touchBegan(3, kind: .pencil)
        #expect(arbiter.touchBegan(4, kind: .finger)
            == [.rejectTouch(4), .cancelCameraGestures])  // palm rejection
    }
}

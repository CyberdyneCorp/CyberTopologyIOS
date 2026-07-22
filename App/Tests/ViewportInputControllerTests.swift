import CyberKitTesting
import Testing
import UIKit
@testable import CyberTopology

/// Deterministic UITouch stand-in: the UIKit layer only reads type,
/// location, timestamp, force and Pencil angles, all overridable.
@MainActor
private final class StubTouch: UITouch {
    private let stubType: UITouch.TouchType
    var stubLocation: CGPoint
    var stubTimestamp: TimeInterval
    var stubForce: CGFloat
    var stubMaxForce: CGFloat
    var stubAzimuth: CGFloat
    var stubAltitude: CGFloat

    init(
        type: UITouch.TouchType, location: CGPoint, timestamp: TimeInterval,
        force: CGFloat = 0, maxForce: CGFloat = 0,
        azimuth: CGFloat = 0, altitude: CGFloat = 0
    ) {
        stubType = type
        stubLocation = location
        stubTimestamp = timestamp
        stubForce = force
        stubMaxForce = maxForce
        stubAzimuth = azimuth
        stubAltitude = altitude
        super.init()
    }

    /// UIKit mutates ONE `UITouch` instance across a touch's lifetime and
    /// identity is how the controller tracks it — tests advance the same
    /// stub instead of allocating a new one per phase.
    func advance(
        to location: CGPoint, timestamp: TimeInterval,
        force: CGFloat? = nil, azimuth: CGFloat? = nil, altitude: CGFloat? = nil
    ) {
        stubLocation = location
        stubTimestamp = timestamp
        if let force { stubForce = force }
        if let azimuth { stubAzimuth = azimuth }
        if let altitude { stubAltitude = altitude }
    }

    override var type: UITouch.TouchType { stubType }
    override var timestamp: TimeInterval { stubTimestamp }
    override var force: CGFloat { stubForce }
    override var maximumPossibleForce: CGFloat { stubMaxForce }
    override var altitudeAngle: CGFloat { stubAltitude }
    override func location(in view: UIView?) -> CGPoint { stubLocation }
    override func azimuthAngle(in view: UIView?) -> CGFloat { stubAzimuth }
}

/// Deterministic UIEvent stand-in delivering a fixed coalesced-touch array
/// (the controller only calls `coalescedTouches(for:)`).
@MainActor
private final class StubEvent: UIEvent {
    var coalesced: [UITouch] = []
    override func coalescedTouches(for touch: UITouch) -> [UITouch]? { coalesced }
}

/// Probe consumer recording the exact event/sample stream.
private struct ProbeConsumer: StrokeConsumer {
    var events: [String] = []
    var samples: [StrokeSample] = []

    mutating func strokeBegan() { events.append("began") }
    mutating func consume(_ sample: StrokeSample) {
        events.append("sample")
        samples.append(sample)
    }
    mutating func strokeEnded() { events.append("ended") }
    mutating func strokeCancelled() { events.append("cancelled") }
}

@MainActor
struct ViewportInputControllerTests {
    /// Holds the view strongly: `referenceView` is weak, and sample
    /// normalization needs its bounds for the whole test.
    private struct Harness {
        let controller: ViewportInputController
        let view: UIView
    }

    private func makeHarness() -> Harness {
        let controller = ViewportInputController(
            capture: ViewportStrokeCapture(consumer: ProbeConsumer())
        )
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        controller.referenceView = view
        return Harness(controller: controller, view: view)
    }

    private func probe(_ controller: ViewportInputController) -> ProbeConsumer {
        controller.capture.consumer as? ProbeConsumer ?? ProbeConsumer()
    }

    // MARK: - Pencil capture and normalization

    @Test func pencilStrokeIsCapturedNormalizedAndRebased() throws {
        let harness = makeHarness()
        let controller = harness.controller
        let touch = StubTouch(
            type: .pencil, location: CGPoint(x: 100, y: 25), timestamp: 500.0,
            force: 2, maxForce: 4, azimuth: 1.25, altitude: 0.6
        )
        controller.touchesBegan([touch])
        touch.advance(
            to: CGPoint(x: 200, y: 100), timestamp: 500.1,
            force: 4, azimuth: 1.3, altitude: 0.5
        )
        controller.touchesMoved([touch])
        controller.touchesEnded([touch])

        let stroke = try #require(controller.capture.lastStroke)
        #expect(stroke.source == .pencil)
        #expect(stroke.verb == .pencil)
        // Ended-with-final-sample: began + moved + touch-up point.
        #expect(stroke.samples.count == 3)

        let first = stroke.samples[0]
        #expect(first.time == 0)  // rebased to stroke start
        #expect(abs(first.x - 0.5) < 1e-9)  // 100 / 200
        #expect(abs(first.y - 0.25) < 1e-9)  // 25 / 100
        #expect(abs(first.pressure - 0.5) < 1e-9)  // 2 / 4
        #expect(abs(first.azimuth - 1.25) < 1e-9)
        #expect(abs(first.altitude - 0.6) < 1e-9)
        #expect(first.type == .pencil)

        let second = stroke.samples[1]
        #expect(abs(second.time - 0.1) < 1e-6)
        #expect(abs(second.x - 1.0) < 1e-9)
        #expect(abs(second.y - 1.0) < 1e-9)

        // The consumer saw the full began → samples → ended hand-off.
        let consumer = probe(controller)
        #expect(consumer.events.first == "began")
        #expect(consumer.events.last == "ended")
        #expect(consumer.samples == stroke.samples)
    }

    /// Regression: 120–240 Hz digitizer samples arrive bundled as coalesced
    /// touches on display-rate event delivery — the capture must append
    /// EVERY coalesced sample (in digitizer order), not just the delivered
    /// touch, or Pencil strokes lose half their density and sharp corners
    /// round out before the recognizer sees them.
    @Test func coalescedTouchesAreCapturedAtFullDensity() throws {
        let harness = makeHarness()
        let controller = harness.controller
        let touch = StubTouch(type: .pencil, location: .zero, timestamp: 1.0)
        controller.touchesBegan([touch])

        // One delivered move carrying an intermediate digitizer sample.
        let intermediate = StubTouch(
            type: .pencil, location: CGPoint(x: 50, y: 25), timestamp: 1.008
        )
        touch.advance(to: CGPoint(x: 100, y: 50), timestamp: 1.016)
        let event = StubEvent()
        event.coalesced = [intermediate, touch]
        controller.touchesMoved([touch], with: event)
        controller.touchesEnded([touch])

        let stroke = try #require(controller.capture.lastStroke)
        // began + BOTH coalesced samples + touch-up point.
        #expect(stroke.samples.count == 4)
        let mid = stroke.samples[1]
        #expect(abs(mid.x - 0.25) < 1e-9)  // 50 / 200 (intermediate)
        #expect(abs(mid.y - 0.25) < 1e-9)  // 25 / 100
        #expect(abs(mid.time - 0.008) < 1e-6)
        let delivered = stroke.samples[2]
        #expect(abs(delivered.x - 0.5) < 1e-9)  // 100 / 200
        #expect(abs(delivered.time - 0.016) < 1e-6)
    }

    /// A rejected (palm) touch stays inert even when its moves carry
    /// coalesced samples.
    @Test func coalescedSamplesOfRejectedTouchesAreNotCaptured() {
        let harness = makeHarness()
        let controller = harness.controller
        let pen = StubTouch(type: .pencil, location: .zero, timestamp: 1.0)
        controller.touchesBegan([pen])
        let palm = StubTouch(type: .direct, location: CGPoint(x: 150, y: 90), timestamp: 1.01)
        controller.touchesBegan([palm])

        let event = StubEvent()
        event.coalesced = [
            StubTouch(type: .direct, location: CGPoint(x: 151, y: 91), timestamp: 1.02),
            palm,
        ]
        controller.touchesMoved([palm], with: event)
        #expect(probe(controller).events == ["began", "sample"])  // pen only
    }

    // MARK: - Fingers never author (spec scenario "Finger strokes never author")

    /// A finger tracing a quad-shaped path through the REAL UIKit glue
    /// captures nothing — no stroke, no consumer events — while the camera
    /// gate keeps admitting the finger (it orbits instead of authoring).
    @Test func fingerQuadShapedStrokeIsNeverCapturedAndStaysCameraEligible() {
        let harness = makeHarness()
        let controller = harness.controller
        let corners: [(CGPoint, TimeInterval)] = [
            (CGPoint(x: 40, y: 20), 1.00),
            (CGPoint(x: 160, y: 20), 1.05),
            (CGPoint(x: 160, y: 80), 1.10),
            (CGPoint(x: 40, y: 80), 1.15),
            (CGPoint(x: 40, y: 20), 1.20),
        ]
        let touch = StubTouch(type: .direct, location: corners[0].0, timestamp: corners[0].1)
        #expect(controller.shouldReceive(touch, for: .camera))
        controller.touchesBegan([touch])
        for (location, time) in corners.dropFirst() {
            touch.advance(to: location, timestamp: time)
            controller.touchesMoved([touch])
        }
        #expect(controller.shouldReceive(touch, for: .camera))
        controller.touchesEnded([touch])

        #expect(controller.capture.lastStroke == nil)
        #expect(probe(controller).events.isEmpty)
    }

    // MARK: - Palm rejection glue (spec scenario "Palm rejection during pen stroke")

    @Test func palmTouchesDuringPenStrokeDoNotAuthorOrReachCameraGates() throws {
        let harness = makeHarness()
        let controller = harness.controller
        let pen = StubTouch(type: .pencil, location: CGPoint(x: 100, y: 50), timestamp: 2.0)
        controller.touchesBegan([pen])

        let palm = StubTouch(type: .direct, location: CGPoint(x: 150, y: 90), timestamp: 2.05)
        // Every recognizer class refuses the palm at the gate…
        #expect(!controller.shouldReceive(palm, for: .camera))
        #expect(!controller.shouldReceive(palm, for: .undoTap))
        #expect(controller.shouldReceive(palm, for: .observer))

        // …and after it lands it neither authors nor disturbs the stroke.
        controller.touchesBegan([palm])
        controller.touchesMoved([palm])
        let events = probe(controller).events
        #expect(events == ["began", "sample"])  // pen stroke only

        controller.touchesEnded([pen, palm])
        let stroke = try #require(controller.capture.lastStroke)
        #expect(stroke.source == .pencil)
    }

    @Test func pencilAndPalmInTheSameEventBatchStillFavorThePencil() throws {
        let harness = makeHarness()
        let controller = harness.controller
        // The palm's timestamp is EARLIER, but pencil-priority ordering
        // rejects it anyway.
        let palm = StubTouch(type: .direct, location: CGPoint(x: 150, y: 90), timestamp: 1.99)
        let pen = StubTouch(type: .pencil, location: CGPoint(x: 100, y: 50), timestamp: 2.0)
        controller.touchesBegan([palm, pen])
        controller.touchesEnded([pen, palm])

        let stroke = try #require(controller.capture.lastStroke)
        #expect(stroke.source == .pencil)
        #expect(probe(controller).events.contains("ended"))
    }

    /// Regression (palm-rejection race): UIKit evaluates `shouldReceive`
    /// for a palm BEFORE the observer sees the batch, so a palm delivered
    /// in the same event batch as the pen-down is admitted to the camera/
    /// undo recognizers while `isPenDown` is still false. Processing the
    /// batch must then fire the cancel callback so the admitted recognizer
    /// is reset — otherwise the resting palm steers the camera (or fires
    /// undo) for the whole pen stroke.
    @Test func palmAdmittedInThePenDownBatchTriggersARecognizerReset() {
        let harness = makeHarness()
        let controller = harness.controller
        var cancelled = 0
        controller.onCancelCameraGestures = { cancelled += 1 }

        let palm = StubTouch(type: .direct, location: CGPoint(x: 150, y: 90), timestamp: 1.99)
        let pen = StubTouch(type: .pencil, location: CGPoint(x: 100, y: 50), timestamp: 2.0)
        // The gate runs first and ADMITS the palm — the pen is not down yet.
        #expect(controller.shouldReceive(palm, for: .camera))
        #expect(controller.shouldReceive(palm, for: .undoTap))

        // The batch lands: pencil is arbitrated first, the palm is rejected,
        // and the reset callback evicts it from the admitted recognizers.
        controller.touchesBegan([palm, pen])
        #expect(cancelled == 1)

        // The pen stroke is untouched by the reset.
        controller.touchesEnded([pen, palm])
        #expect(controller.capture.lastStroke?.source == .pencil)
    }

    // MARK: - Pen priority over camera gestures in flight

    @Test func penDuringCameraFingersFiresTheCancelCallback() {
        let harness = makeHarness()
        let controller = harness.controller
        var cancelled = 0
        controller.onCancelCameraGestures = { cancelled += 1 }

        let fingers = [
            StubTouch(type: .direct, location: CGPoint(x: 50, y: 50), timestamp: 3.0),
            StubTouch(type: .direct, location: CGPoint(x: 150, y: 50), timestamp: 3.0),
        ]
        controller.touchesBegan(Set(fingers))
        let pen = StubTouch(type: .pencil, location: CGPoint(x: 100, y: 50), timestamp: 3.1)
        controller.touchesBegan([pen])
        #expect(cancelled == 1)
    }

    // MARK: - Gates route through the arbiter

    @Test func pencilIsRefusedByEveryGateExceptTheObserver() {
        let harness = makeHarness()
        let controller = harness.controller
        let pen = StubTouch(type: .pencil, location: .zero, timestamp: 0)
        #expect(controller.shouldReceive(pen, for: .observer))
        #expect(!controller.shouldReceive(pen, for: .camera))
        #expect(!controller.shouldReceive(pen, for: .undoTap))
    }

    @Test func thirdFingerIsRefusedAtTheCameraGates() {
        let harness = makeHarness()
        let controller = harness.controller
        let fingers = [
            StubTouch(type: .direct, location: CGPoint(x: 20, y: 20), timestamp: 4.0),
            StubTouch(type: .direct, location: CGPoint(x: 60, y: 20), timestamp: 4.0),
        ]
        controller.touchesBegan(Set(fingers))

        let third = StubTouch(type: .direct, location: CGPoint(x: 100, y: 20), timestamp: 4.1)
        #expect(!controller.shouldReceive(third, for: .camera))
        #expect(controller.shouldReceive(third, for: .undoTap))  // 3-finger undo

        // An already-registered second finger is still admitted (gating is
        // order-independent: the asked touch never counts against itself).
        #expect(controller.shouldReceive(fingers[1], for: .camera))
    }

    @Test func touchCancellationCancelsTheStroke() {
        let harness = makeHarness()
        let controller = harness.controller
        let pen = StubTouch(type: .pencil, location: CGPoint(x: 10, y: 10), timestamp: 5.0)
        controller.touchesBegan([pen])
        controller.touchesCancelled([pen])
        #expect(probe(controller).events == ["began", "sample", "cancelled"])
        #expect(controller.capture.lastStroke == nil)
    }

    // MARK: - Fixture-recorder integration (task 1.1b harness)

    @Test func capturedStrokeRoundTripsThroughAFixtureReplay() throws {
        let harness = makeHarness()
        let controller = harness.controller
        let points: [(CGPoint, TimeInterval)] = [
            (CGPoint(x: 40, y: 20), 10.00),
            (CGPoint(x: 160, y: 20), 10.05),
            (CGPoint(x: 160, y: 80), 10.10),
            (CGPoint(x: 40, y: 80), 10.15),
        ]
        let touch = StubTouch(type: .pencil, location: points[0].0, timestamp: points[0].1)
        controller.touchesBegan([touch])
        for (location, time) in points.dropFirst() {
            touch.advance(to: location, timestamp: time)
            controller.touchesMoved([touch])
        }
        touch.advance(to: points[3].0, timestamp: 10.2)
        controller.touchesEnded([touch])

        // Save the captured stroke as a task-1.1b fixture…
        let fixture = try #require(
            controller.capture.fixture(named: "captured-quad", expectedOutcome: "quad-create")
        )
        #expect(fixture.schemaVersion == StrokeFixture.currentSchemaVersion)
        #expect(fixture.samples.first?.time == 0)

        // …and replay it through the shared harness: the replayed stream is
        // exactly what the live consumer saw.
        var replayProbe = ProbeConsumer()
        StrokeReplayer.replay(fixture, into: &replayProbe)
        let liveProbe = probe(controller)
        #expect(replayProbe.samples == liveProbe.samples)
        #expect(replayProbe.events == liveProbe.events)
    }

    // MARK: - Verb plumbing

    @Test func verbEventsForwardToTheArbiter() {
        let harness = makeHarness()
        let controller = harness.controller
        controller.verbPressBegan(.relax, at: 0)
        #expect(controller.activeVerb == .relax)
        controller.verbPressEnded(.relax, at: 1.0)
        #expect(controller.activeVerb == .pencil)
        controller.selectVerb(.erase)
        #expect(controller.activeVerb == .erase)
    }

    // MARK: - Debug consumer

    @Test func debugConsumerCountsSamplesAndStrokes() {
        var consumer = DebugStrokeConsumer()
        consumer.strokeBegan()
        consumer.consume(StrokeSample(time: 0, x: 0.1, y: 0.1))
        consumer.consume(StrokeSample(time: 0.1, x: 0.2, y: 0.2))
        consumer.strokeEnded()
        #expect(consumer.sampleCount == 2)
        #expect(consumer.finishedStrokes == 1)

        consumer.strokeBegan()
        consumer.consume(StrokeSample(time: 0, x: 0.3, y: 0.3))
        consumer.strokeCancelled()
        #expect(consumer.cancelledStrokes == 1)
        #expect(consumer.finishedStrokes == 1)
    }
}

import CyberKit
import CyberKitTesting
import Testing
import UIKit
@testable import CyberTopology

/// Live ink trail (spec: pencil-interaction / "Live stroke feedback").
///
/// The ink is Core Animation content over the Metal view, so these assert
/// the layer-facing behaviour directly: what is drawn, when it clears, and
/// that it never grows without bound.
@MainActor
struct LiveStrokeInkTests {
    private func attachedInk(size: CGFloat = 100) -> (LiveStrokeInk, UIView) {
        let ink = LiveStrokeInk()
        let view = UIView(frame: CGRect(x: 0, y: 0, width: size, height: size))
        ink.attach(to: view)
        return (ink, view)
    }

    @Test func nothingIsDrawnBeforeAStrokeBegins() {
        let (ink, _) = attachedInk()
        #expect(!ink.isActive)
        #expect(!ink.isVisible)
    }

    /// A single sample has no segment. Drawing a dot there would read as a
    /// committed vertex, which is a different thing entirely.
    @Test func aSingleSampleDrawsNothingYet() {
        let (ink, _) = attachedInk()
        ink.begin(at: CGPoint(x: 0.5, y: 0.5))
        #expect(ink.isActive)
        #expect(!ink.isVisible)
    }

    @Test func twoSamplesDrawATrail() {
        let (ink, _) = attachedInk()
        ink.begin(at: CGPoint(x: 0.2, y: 0.2))
        ink.append(CGPoint(x: 0.8, y: 0.8))
        #expect(ink.isVisible)
        #expect(ink.pointCount == 2)
    }

    /// The trail must clear when the stroke ends: the committed result is
    /// what the user should see next, and leaving ink up double-draws the
    /// gesture over its own outcome.
    @Test func endingClearsTheTrail() {
        let (ink, _) = attachedInk()
        ink.begin(at: CGPoint(x: 0.2, y: 0.2))
        ink.append(CGPoint(x: 0.8, y: 0.8))
        #expect(ink.isVisible)

        ink.end()
        #expect(!ink.isActive)
        #expect(!ink.isVisible)
        #expect(ink.pointCount == 0)
    }

    /// Cancellation goes through the same clear path — an abandoned stroke
    /// must not leave ink behind.
    @Test func endingIsIdempotent() {
        let (ink, _) = attachedInk()
        ink.begin(at: CGPoint(x: 0.1, y: 0.1))
        ink.end()
        ink.end()
        #expect(!ink.isVisible)
    }

    /// Samples arriving without a begin (a stroke that started before the
    /// layer attached) must not draw a trail from nowhere.
    @Test func samplesWithoutABeginAreIgnored() {
        let (ink, _) = attachedInk()
        ink.append(CGPoint(x: 0.5, y: 0.5))
        #expect(ink.pointCount == 0)
        #expect(!ink.isVisible)
    }

    /// A long slow stroke at 240 Hz must not grow the retained path without
    /// bound; oldest points drop first.
    @Test func retainedPointsAreCapped() {
        let (ink, _) = attachedInk()
        ink.begin(at: .zero)
        for index in 0..<(LiveStrokeInk.maximumPoints + 500) {
            ink.append(CGPoint(x: Double(index % 100) / 100.0, y: 0.5))
        }
        #expect(ink.pointCount == LiveStrokeInk.maximumPoints)
    }

    /// A zero-sized layer (before first layout) must not crash or draw.
    @Test func aZeroSizedLayerDrawsNothing() {
        let ink = LiveStrokeInk()
        let view = UIView(frame: .zero)
        ink.attach(to: view)
        ink.begin(at: CGPoint(x: 0.2, y: 0.2))
        ink.append(CGPoint(x: 0.8, y: 0.8))
        #expect(!ink.isVisible)
    }

    /// Beginning a second stroke replaces the first rather than appending
    /// to it — two gestures must never join into one trail.
    @Test func beginningAgainReplacesThePreviousTrail() {
        let (ink, _) = attachedInk()
        ink.begin(at: CGPoint(x: 0.1, y: 0.1))
        ink.append(CGPoint(x: 0.2, y: 0.2))
        ink.append(CGPoint(x: 0.3, y: 0.3))
        #expect(ink.pointCount == 3)

        ink.begin(at: CGPoint(x: 0.9, y: 0.9))
        #expect(ink.pointCount == 1)
    }
}

/// The input model must publish live samples on the same turn they arrive,
/// or the trail lags the pen — the whole reason the ink exists.
@MainActor
struct LiveStrokeFeedTests {
    @Test func strokeSamplesArePublishedAsTheyArrive() {
        let model = ViewportInputModel()
        var began: [CGPoint] = []
        var samples: [CGPoint] = []
        var endedCount = 0

        model.onLiveStrokeBegan = { began.append($0) }
        model.onLiveStrokeSample = { samples.append($0) }
        model.onLiveStrokeEnded = { endedCount += 1 }

        let capture = model.controller.capture
        capture.begin(source: .pencil, verb: .pencil, sample: sample(0.1, 0.1, at: 0))
        capture.append(sample: sample(0.2, 0.2, at: 0.01))
        capture.append(sample: sample(0.3, 0.3, at: 0.02))

        // Published DURING the stroke, not after it finishes.
        #expect(began.count == 1)
        #expect(samples.count == 2)
        #expect(endedCount == 0)

        capture.end(sample: sample(0.4, 0.4, at: 0.03))
        #expect(endedCount == 1)
    }

    /// A cancelled stroke clears the ink too.
    @Test func cancellationEndsTheTrail() {
        let model = ViewportInputModel()
        var endedCount = 0
        model.onLiveStrokeEnded = { endedCount += 1 }

        let capture = model.controller.capture
        capture.begin(source: .pencil, verb: .pencil, sample: sample(0.1, 0.1, at: 0))
        capture.append(sample: sample(0.2, 0.2, at: 0.01))
        capture.cancel()

        #expect(endedCount == 1)
    }

    private func sample(_ x: Double, _ y: Double, at time: TimeInterval) -> StrokeSample {
        StrokeSample(time: time, x: x, y: y)
    }
}

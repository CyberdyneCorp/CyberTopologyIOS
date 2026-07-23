import CyberKitTesting
import Foundation
import os

/// Capture side of the authoring pipeline (task 3.1 item 4): the samples of
/// whichever touch the `InputArbiter` routed to authoring are recorded in
/// the task-1.1b `StrokeSample` format (normalized coordinates, pressure,
/// azimuth, altitude, touch type) and streamed to a `StrokeConsumer`.
///
/// The consumer is the task-3.2 engine recognizer facade; until it lands,
/// `DebugStrokeConsumer` logs sample counts. Completed strokes are also kept
/// as `CapturedStroke` so live input can be saved as replayable
/// `StrokeFixture`s (the fixture-recorder integration path).
@MainActor
final class ViewportStrokeCapture {
    struct CapturedStroke: Equatable {
        var samples: [StrokeSample]
        var source: InputArbiter.StrokeSource
        var verb: InputArbiter.Verb
    }

    /// Downstream recognizer. Swappable so tests probe the stream and 3.2
    /// plugs the real recognizer in without touching the capture side.
    var consumer: any StrokeConsumer
    /// Fires after `end` with the completed stroke (drives the debug HUD).
    var onStrokeFinished: ((CapturedStroke) -> Void)?
    /// Live-verb hooks (task 3.3): fired as samples arrive so the mesh-edit
    /// controller can apply Relax/Move/Tweak/Erase during the scrub, and on
    /// cancellation so it can discard the session. `onStrokeBegan` fires
    /// with the (rebased) first sample; `onSampleAppended` for every later
    /// one.
    var onStrokeBegan: ((InputArbiter.Verb, InputArbiter.StrokeSource, StrokeSample) -> Void)?
    var onSampleAppended: ((StrokeSample) -> Void)?
    var onStrokeCancelled: (() -> Void)?

    private(set) var activeStroke: CapturedStroke?
    private(set) var lastStroke: CapturedStroke?
    /// First-sample absolute timestamp; samples are rebased to it so the
    /// stroke starts at t=0 exactly like recorded fixtures.
    private var startTime: TimeInterval?

    init(consumer: any StrokeConsumer = DebugStrokeConsumer()) {
        self.consumer = consumer
    }

    /// Begins a stroke with its first sample. `sample.time` is absolute
    /// (e.g. `UITouch.timestamp`); it is rebased internally.
    func begin(
        source: InputArbiter.StrokeSource, verb: InputArbiter.Verb, sample: StrokeSample
    ) {
        activeStroke = CapturedStroke(samples: [], source: source, verb: verb)
        startTime = nil
        consumer.strokeBegan()
        append(sample: sample)
    }

    func append(sample: StrokeSample) {
        guard let stroke = activeStroke else { return }
        let rebased = rebase(sample)
        activeStroke?.samples.append(rebased)
        consumer.consume(rebased)
        if stroke.samples.isEmpty {
            onStrokeBegan?(stroke.verb, stroke.source, rebased)
        } else {
            onSampleAppended?(rebased)
        }
    }

    /// Ends the stroke, optionally with a final sample (the touch-up point).
    func end(sample: StrokeSample? = nil) {
        if let sample { append(sample: sample) }
        guard let stroke = activeStroke else { return }
        activeStroke = nil
        startTime = nil
        consumer.strokeEnded()
        lastStroke = stroke
        onStrokeFinished?(stroke)
    }

    /// Aborts the stroke (palm rejection, second finger flipping to
    /// navigation, touch cancellation). Nothing is published.
    func cancel() {
        guard activeStroke != nil else { return }
        activeStroke = nil
        startTime = nil
        consumer.strokeCancelled()
        onStrokeCancelled?()
    }

    /// The last completed stroke as a replayable fixture (task 1.1b format).
    func fixture(
        named name: String, expectedOutcome: String, provenance: String? = nil
    ) -> StrokeFixture? {
        guard let stroke = lastStroke else { return nil }
        return StrokeFixture(
            name: name, samples: stroke.samples, expectedOutcome: expectedOutcome,
            provenance: provenance
        )
    }

    private func rebase(_ sample: StrokeSample) -> StrokeSample {
        let start = startTime ?? sample.time
        startTime = start
        return StrokeSample(
            time: sample.time - start, x: sample.x, y: sample.y,
            pressure: sample.pressure, azimuth: sample.azimuth,
            altitude: sample.altitude, type: sample.type
        )
    }
}

/// Placeholder consumer until the task-3.2 recognizer lands: logs sample
/// counts so captured strokes are visible in the console during dogfooding.
struct DebugStrokeConsumer: StrokeConsumer {
    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "CyberTopology", category: "stroke-capture"
    )

    private(set) var sampleCount = 0
    private(set) var finishedStrokes = 0
    private(set) var cancelledStrokes = 0

    mutating func strokeBegan() {
        sampleCount = 0
    }

    mutating func consume(_ sample: StrokeSample) {
        sampleCount += 1
    }

    mutating func strokeEnded() {
        finishedStrokes += 1
        let (stroke, samples) = (finishedStrokes, sampleCount)
        Self.log.debug("stroke #\(stroke) ended: \(samples) samples")
    }

    mutating func strokeCancelled() {
        cancelledStrokes += 1
        let samples = sampleCount
        Self.log.debug("stroke cancelled after \(samples) samples")
    }
}

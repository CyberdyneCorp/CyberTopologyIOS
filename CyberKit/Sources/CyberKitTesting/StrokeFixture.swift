import Foundation

/// One timestamped input sample of a recorded stroke (task 1.1b, spec:
/// quality-assurance / "Gesture grammar regression suite").
///
/// Platform-neutral on purpose: UIKit/PencilKit events are converted into
/// this shape at the recording site, and the phase-3 engine gesture
/// recognizer consumes fixtures without any UIKit dependency.
public struct StrokeSample: Codable, Equatable, Sendable {
    public enum TouchType: String, Codable, Equatable, Sendable {
        case pencil
        case finger
    }

    /// Seconds since the first sample of the stroke.
    public let time: TimeInterval
    /// Viewport-normalized coordinates (0...1 on each axis, origin top-left)
    /// so fixtures replay identically across screen sizes.
    public let x: Double
    public let y: Double
    /// Normalized pressure (0...1); 0 for finger input.
    public let pressure: Double
    /// Pencil azimuth in radians; 0 for finger input.
    public let azimuth: Double
    /// Pencil altitude in radians; 0 for finger input.
    public let altitude: Double
    public let type: TouchType

    public init(
        time: TimeInterval, x: Double, y: Double, pressure: Double = 0,
        azimuth: Double = 0, altitude: Double = 0, type: TouchType = .pencil
    ) {
        self.time = time
        self.x = x
        self.y = y
        self.pressure = pressure
        self.azimuth = azimuth
        self.altitude = altitude
        self.type = type
    }
}

/// A recorded stroke plus the outcome it is expected to produce, stored as
/// JSON under the test fixtures directory.
///
/// `expectedOutcome` is a free-form descriptor for now (e.g. "quad-create",
/// "loop-insert:ring-7"); it becomes a typed interpretation record when the
/// phase-3 recognizer lands.
public struct StrokeFixture: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var name: String
    public var samples: [StrokeSample]
    public var expectedOutcome: String

    public init(name: String, samples: [StrokeSample], expectedOutcome: String) {
        self.schemaVersion = Self.currentSchemaVersion
        self.name = name
        self.samples = samples
        self.expectedOutcome = expectedOutcome
    }

    // MARK: - Persistence

    public init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        self = try JSONDecoder().decode(StrokeFixture.self, from: data)
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// Builds a `StrokeFixture` from live input events: feed samples as they
/// arrive, then `finish`. Timestamps are rebased so the first sample is at
/// t=0, keeping fixtures replayable and diffable.
public struct StrokeRecorder {
    private var samples: [StrokeSample] = []
    private var startTime: TimeInterval?

    public init() {}

    /// Adds a sample with an absolute timestamp (e.g. `UITouch.timestamp`).
    public mutating func add(
        absoluteTime: TimeInterval, x: Double, y: Double, pressure: Double = 0,
        azimuth: Double = 0, altitude: Double = 0, type: StrokeSample.TouchType = .pencil
    ) {
        let start = startTime ?? absoluteTime
        startTime = start
        samples.append(StrokeSample(
            time: absoluteTime - start, x: x, y: y, pressure: pressure,
            azimuth: azimuth, altitude: altitude, type: type
        ))
    }

    /// Finalizes the recording into a named fixture.
    public func finish(name: String, expectedOutcome: String) -> StrokeFixture {
        StrokeFixture(name: name, samples: samples, expectedOutcome: expectedOutcome)
    }
}

/// Consumer side of stroke replay. The phase-3 gesture recognizer conforms;
/// tests conform with probes.
public protocol StrokeConsumer {
    mutating func strokeBegan()
    mutating func consume(_ sample: StrokeSample)
    mutating func strokeEnded()
    /// An in-flight stroke was aborted (palm rejection, a second finger
    /// flipping the interaction to navigation, touch cancellation). The
    /// default forwards to `strokeEnded()` so pre-existing conformers stay
    /// source-compatible; consumers that must not interpret aborted strokes
    /// (the recognizer) override it to discard.
    mutating func strokeCancelled()
}

extension StrokeConsumer {
    public mutating func strokeCancelled() { strokeEnded() }
}

/// Feeds a fixture's samples, in recorded order, into a `StrokeConsumer`.
public enum StrokeReplayer {
    /// Immediate replay (no timing): the default for deterministic tests.
    public static func replay(_ fixture: StrokeFixture, into consumer: inout some StrokeConsumer) {
        consumer.strokeBegan()
        for sample in fixture.samples.sorted(by: { $0.time < $1.time }) {
            consumer.consume(sample)
        }
        consumer.strokeEnded()
    }
}

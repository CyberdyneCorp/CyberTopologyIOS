import Foundation

/// Programmatic recorder for the committed gesture-fixture corpus (task
/// 3.2; spec: quality-assurance / "Gesture grammar regression suite").
///
/// Each generator "draws" one grammar shape as a real sample sequence —
/// 120 Hz timestamps, plausible pen speed, a pressure profile, and a small
/// deterministic wobble so the tolerance-forgiveness of the classifier is
/// actually exercised. The JSON fixtures under
/// `CyberKit/Tests/CyberKitTests/Fixtures/Strokes/` are generated from
/// these functions and committed; the regression suite replays the
/// COMMITTED files through the real engine recognizer, and a provenance
/// test pins file == generator so the corpus can never silently drift.
///
/// Everything is pure math — no RNG, no clock — so regeneration is
/// bit-identical on every machine.
public enum StrokeGestureCorpus {
    /// 120 Hz Pencil sample cadence.
    public static let sampleInterval: TimeInterval = 1.0 / 120.0
    /// Pen travel speed in normalized viewport units per second.
    static let penSpeed = 0.9
    /// Hand-wobble amplitude in normalized units (the "sloppy stroke" the
    /// spec demands tolerance for).
    static let wobble = 0.004

    // MARK: - Shape recordings

    /// Closed ~square starting/ending near the same corner (quad draw).
    public static func square(type: StrokeSample.TouchType = .pencil) -> StrokeFixture {
        fixture(
            name: type == .pencil ? "square_pencil" : "square_finger",
            expectedOutcome: "closedLoop:createQuad",
            points: path(through: [
                Point(0.32, 0.30), Point(0.68, 0.31), Point(0.69, 0.68),
                Point(0.31, 0.69), Point(0.32, 0.32),
            ]),
            type: type
        )
    }

    /// Straight diagonal line.
    public static func line(type: StrokeSample.TouchType = .pencil) -> StrokeFixture {
        fixture(
            name: type == .pencil ? "line_pencil" : "line_finger",
            expectedOutcome: "line:toggleVisibility",
            points: path(through: [Point(0.22, 0.75), Point(0.78, 0.28)]),
            type: type
        )
    }

    /// An X drawn in one stroke (down-stroke, hop, down-stroke).
    public static func cross(type: StrokeSample.TouchType = .pencil) -> StrokeFixture {
        fixture(
            name: type == .pencil ? "x_pencil" : "x_finger",
            expectedOutcome: "cross:none",
            points: path(through: [
                Point(0.34, 0.34), Point(0.66, 0.66), Point(0.66, 0.34),
                Point(0.34, 0.66),
            ]),
            type: type
        )
    }

    /// Tight zig-zag scribble.
    public static func scribble(type: StrokeSample.TouchType = .pencil) -> StrokeFixture {
        fixture(
            name: type == .pencil ? "scribble_pencil" : "scribble_finger",
            expectedOutcome: "scribble:none",
            points: path(through: [
                Point(0.32, 0.52), Point(0.40, 0.36), Point(0.45, 0.60),
                Point(0.53, 0.37), Point(0.58, 0.61), Point(0.66, 0.40),
            ]),
            type: type
        )
    }

    /// Round closed circle.
    public static func circle(type: StrokeSample.TouchType = .pencil) -> StrokeFixture {
        var points: [Point] = []
        let steps = 96
        for i in 0...steps {
            let angle = 2.0 * Double.pi * Double(i) / Double(steps)
            points.append(Point(0.5 + 0.17 * cos(angle), 0.5 + 0.17 * sin(angle)))
        }
        return fixture(
            name: type == .pencil ? "circle_pencil" : "circle_finger",
            expectedOutcome: "circle:createQuad",
            points: points,
            type: type
        )
    }

    /// Stationary press-and-hold.
    public static func holdPoint(type: StrokeSample.TouchType = .pencil) -> StrokeFixture {
        var samples: [StrokeSample] = []
        let count = 60  // 0.5 s at 120 Hz
        for i in 0...count {
            let time = Double(i) * sampleInterval
            // Sub-pixel tremble around the hold point.
            let x = 0.55 + 0.0015 * sin(Double(i) * 1.3)
            let y = 0.45 + 0.0015 * cos(Double(i) * 1.7)
            samples.append(sample(x: x, y: y, time: time, index: i, of: count, type: type))
        }
        return StrokeFixture(
            name: type == .pencil ? "hold_pencil" : "hold_finger",
            samples: samples,
            expectedOutcome: "holdPoint:none"
        )
    }

    /// Irregular closed lasso (kidney-shaped blob).
    public static func lasso(type: StrokeSample.TouchType = .pencil) -> StrokeFixture {
        var points: [Point] = []
        let steps = 110
        for i in 0...steps {
            let angle = 2.0 * Double.pi * Double(i) / Double(steps)
            let radius = 0.16 + 0.07 * sin(2 * angle) + 0.03 * sin(3 * angle)
            points.append(Point(0.5 + radius * cos(angle), 0.5 + radius * sin(angle)))
        }
        return fixture(
            name: type == .pencil ? "lasso_pencil" : "lasso_finger",
            expectedOutcome: "lasso:hideRegion",
            points: points,
            type: type
        )
    }

    // MARK: - Task 3.4 grammar recordings
    //
    // Stage-1 expected outcomes are what the fixture classifies to WITHOUT
    // mesh context (the committed-corpus replay runs stage-1 only); the
    // grammar tests replay the same files against seeded meshes and assert
    // the stage-2 interpretation and the resulting mesh state.

    /// One-stroke grid: a square wave of four rails (up, down, up, down)
    /// joined by rungs — 3 quad cells in one stroke. Wide on purpose: the
    /// endpoint gap must stay ABOVE the closed-stroke fraction even after
    /// portrait-viewport aspect correction shrinks x distances, or the
    /// wave would misread as a closed loop (quad draw).
    public static func grid(type: StrokeSample.TouchType = .pencil) -> StrokeFixture {
        fixture(
            name: type == .pencil ? "grid_pencil" : "grid_finger",
            expectedOutcome: "grid:createGrid",
            points: path(through: [
                Point(0.22, 0.66), Point(0.22, 0.36), Point(0.42, 0.36),
                Point(0.42, 0.66), Point(0.62, 0.66), Point(0.62, 0.36),
                Point(0.82, 0.36), Point(0.82, 0.66),
            ]),
            type: type
        )
    }

    /// Straight line downward in empty space (invert visibility).
    public static func lineDown(type: StrokeSample.TouchType = .pencil) -> StrokeFixture {
        fixture(
            name: type == .pencil ? "line_down_pencil" : "line_down_finger",
            expectedOutcome: "line:toggleVisibility",
            points: path(through: [Point(0.50, 0.20), Point(0.52, 0.80)]),
            type: type
        )
    }

    /// Straight line upward in empty space (show all).
    public static func lineUp(type: StrokeSample.TouchType = .pencil) -> StrokeFixture {
        fixture(
            name: type == .pencil ? "line_up_pencil" : "line_up_finger",
            expectedOutcome: "line:toggleVisibility",
            points: path(through: [Point(0.50, 0.80), Point(0.48, 0.20)]),
            type: type
        )
    }

    /// Vertical line across the horizontal quad ring of the seeded 3x2
    /// grid strip (grid32.obj under the fixed test projection): full
    /// edge-loop insert.
    public static func ringInsertLine(
        type: StrokeSample.TouchType = .pencil
    ) -> StrokeFixture {
        fixture(
            name: type == .pencil ? "ring_insert_line_pencil" : "ring_insert_line_finger",
            expectedOutcome: "line:toggleVisibility",
            points: path(through: [Point(0.50, 0.15), Point(0.50, 0.85)]),
            type: type
        )
    }

    /// Horizontal line ALONG the middle edge loop of the seeded 3x2 grid
    /// strip: loop tag (the disambiguation counterpart of ringInsertLine).
    public static func loopTagLine(
        type: StrokeSample.TouchType = .pencil
    ) -> StrokeFixture {
        fixture(
            name: type == .pencil ? "loop_tag_line_pencil" : "loop_tag_line_finger",
            expectedOutcome: "line:toggleVisibility",
            points: path(through: [Point(0.25, 0.50), Point(0.75, 0.50)]),
            type: type
        )
    }

    /// Corner-to-corner line over the test cube (v0 → v2): vertex merge.
    public static func mergeLine(type: StrokeSample.TouchType = .pencil) -> StrokeFixture {
        fixture(
            name: type == .pencil ? "merge_line_pencil" : "merge_line_finger",
            expectedOutcome: "line:toggleVisibility",
            points: path(through: [Point(0.10, 0.90), Point(0.90, 0.10)]),
            type: type
        )
    }

    /// Zig-zag across the cube's projected top border edge: edge dissolve.
    public static func dissolveScribble(
        type: StrokeSample.TouchType = .pencil
    ) -> StrokeFixture {
        fixture(
            name: type == .pencil ? "dissolve_scribble_pencil" : "dissolve_scribble_finger",
            expectedOutcome: "scribble:none",
            points: path(through: [
                Point(0.30, 0.08), Point(0.38, 0.13), Point(0.44, 0.07),
                Point(0.52, 0.14), Point(0.58, 0.07), Point(0.66, 0.13),
            ]),
            type: type
        )
    }

    /// Small circle over the midpoint of the cube's projected top border
    /// edge: rotate edge.
    public static func rotateCircle(
        type: StrokeSample.TouchType = .pencil
    ) -> StrokeFixture {
        var points: [Point] = []
        let steps = 72
        for i in 0...steps {
            let angle = 2.0 * Double.pi * Double(i) / Double(steps)
            points.append(Point(0.5 + 0.05 * cos(angle), 0.1 + 0.05 * sin(angle)))
        }
        return fixture(
            name: type == .pencil ? "rotate_circle_pencil" : "rotate_circle_finger",
            expectedOutcome: "circle:createQuad",
            points: points,
            type: type
        )
    }

    /// Irregular closed lasso STARTING in empty space (right of the cube's
    /// projected square) and sweeping across it: hide portion.
    public static func hideLasso(type: StrokeSample.TouchType = .pencil) -> StrokeFixture {
        var points: [Point] = []
        let steps = 140
        for i in 0...steps {
            let angle = 2.0 * Double.pi * Double(i) / Double(steps)
            let radius = 0.36 + 0.09 * sin(2 * angle) + 0.05 * sin(3 * angle)
            points.append(Point(0.58 + radius * cos(angle), 0.5 + radius * sin(angle)))
        }
        return fixture(
            name: type == .pencil ? "hide_lasso_pencil" : "hide_lasso_finger",
            expectedOutcome: "lasso:hideRegion",
            points: points,
            type: type
        )
    }

    /// Quick tap on the cube corner v2 (0.9, 0.1): one half of the
    /// double-tap-to-Tweak gesture (the app replays it twice).
    public static func doubleTap(type: StrokeSample.TouchType = .pencil) -> StrokeFixture {
        var samples: [StrokeSample] = []
        let count = 6  // 50 ms at 120 Hz: a tap, not a hold
        for i in 0...count {
            let time = Double(i) * sampleInterval
            let x = 0.9 + 0.001 * sin(Double(i) * 1.9)
            let y = 0.1 + 0.001 * cos(Double(i) * 1.4)
            samples.append(sample(x: x, y: y, time: time, index: i, of: count, type: type))
        }
        return StrokeFixture(
            name: type == .pencil ? "double_tap_pencil" : "double_tap_finger",
            samples: samples,
            expectedOutcome: "holdPoint:none"
        )
    }

    /// The full committed corpus, in deterministic order. The finger square
    /// exists so the suite can assert recognizer parity between input types
    /// (the UI-test injection hooks replay finger-typed fixtures).
    public static var all: [StrokeFixture] {
        [
            square(), square(type: .finger), line(), cross(), scribble(),
            circle(), holdPoint(), lasso(),
            // Task 3.4 grammar corpus:
            grid(), lineDown(), lineUp(), ringInsertLine(), loopTagLine(),
            mergeLine(), dissolveScribble(), rotateCircle(), hideLasso(),
            doubleTap(),
        ]
    }

    // MARK: - Recording internals

    public struct Point: Sendable {
        public var x: Double
        public var y: Double

        public init(_ x: Double, _ y: Double) {
            self.x = x
            self.y = y
        }
    }

    /// Densifies a waypoint polyline at pen speed, adding the deterministic
    /// perpendicular wobble.
    public static func path(through waypoints: [Point]) -> [Point] {
        var out: [Point] = []
        var traveled = 0.0
        for i in 1..<waypoints.count {
            let a = waypoints[i - 1]
            let b = waypoints[i]
            let dx = b.x - a.x
            let dy = b.y - a.y
            let length = (dx * dx + dy * dy).squareRoot()
            guard length > 0 else { continue }
            let step = penSpeed * sampleInterval
            let count = max(2, Int(length / step))
            // Unit perpendicular for the wobble.
            let px = -dy / length
            let py = dx / length
            for k in 0..<count {
                let t = Double(k) / Double(count)
                let arc = traveled + t * length
                let offset = wobble * sin(arc * 55.0)
                out.append(Point(
                    a.x + dx * t + px * offset,
                    a.y + dy * t + py * offset
                ))
            }
            traveled += length
        }
        if let last = waypoints.last { out.append(last) }
        return out
    }

    public static func fixture(
        name: String, expectedOutcome: String, points: [Point],
        type: StrokeSample.TouchType
    ) -> StrokeFixture {
        let last = max(1, points.count - 1)
        let samples = points.enumerated().map { index, point in
            sample(
                x: point.x, y: point.y, time: Double(index) * sampleInterval,
                index: index, of: last, type: type
            )
        }
        return StrokeFixture(name: name, samples: samples, expectedOutcome: expectedOutcome)
    }

    /// One sample with a plausible pressure bell curve; finger recordings
    /// carry no pressure/attitude, exactly like the live capture path.
    static func sample(
        x: Double, y: Double, time: TimeInterval, index: Int, of total: Int,
        type: StrokeSample.TouchType
    ) -> StrokeSample {
        let progress = total > 0 ? Double(index) / Double(total) : 0
        let pencil = type == .pencil
        return StrokeSample(
            time: time,
            x: x,
            y: y,
            pressure: pencil ? 0.35 + 0.3 * sin(Double.pi * progress) : 0,
            azimuth: pencil ? 1.1 : 0,
            altitude: pencil ? 0.9 : 0,
            type: type
        )
    }
}

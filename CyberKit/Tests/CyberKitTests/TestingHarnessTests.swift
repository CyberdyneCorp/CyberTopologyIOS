import CyberKit
import Foundation
import Testing
@testable import CyberKitTesting

@Suite("Stroke fixtures")
struct StrokeFixtureTests {
    private var sampleFixture: StrokeFixture {
        StrokeFixture(
            name: "quad-draw",
            samples: [
                StrokeSample(time: 0.00, x: 0.2, y: 0.2, pressure: 0.5),
                StrokeSample(time: 0.05, x: 0.8, y: 0.2, pressure: 0.6),
                StrokeSample(time: 0.10, x: 0.8, y: 0.8, pressure: 0.6),
                StrokeSample(time: 0.15, x: 0.2, y: 0.8, pressure: 0.4),
            ],
            expectedOutcome: "quad-create"
        )
    }

    @Test("fixture round-trips through its JSON file format")
    func fileRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixture-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        try sampleFixture.write(to: url)
        let loaded = try StrokeFixture(contentsOf: url)
        #expect(loaded == sampleFixture)
        #expect(loaded.schemaVersion == StrokeFixture.currentSchemaVersion)
    }

    @Test("recorder rebases absolute timestamps to the first sample")
    func recorderRebasesTime() {
        var recorder = StrokeRecorder()
        recorder.add(absoluteTime: 1000.5, x: 0.1, y: 0.1, type: .finger)
        recorder.add(absoluteTime: 1000.6, x: 0.2, y: 0.2, type: .finger)
        let fixture = recorder.finish(name: "probe", expectedOutcome: "none")

        #expect(fixture.samples.count == 2)
        #expect(fixture.samples[0].time == 0)
        #expect(abs(fixture.samples[1].time - 0.1) < 1e-9)
        #expect(fixture.samples[1].type == .finger)
    }

    @Test("replayer delivers began, ordered samples, ended")
    func replayerOrdering() {
        struct Probe: StrokeConsumer {
            var events: [String] = []
            mutating func strokeBegan() { events.append("began") }
            mutating func consume(_ sample: StrokeSample) { events.append("s\(sample.time)") }
            mutating func strokeEnded() { events.append("ended") }
        }
        var probe = Probe()
        StrokeReplayer.replay(sampleFixture, into: &probe)

        #expect(probe.events.first == "began")
        #expect(probe.events.last == "ended")
        #expect(probe.events.count == sampleFixture.samples.count + 2)
        // Samples arrive in time order even if stored shuffled.
        var shuffled = sampleFixture
        shuffled.samples.reverse()
        var probe2 = Probe()
        StrokeReplayer.replay(shuffled, into: &probe2)
        #expect(probe2.events == probe.events)
    }

    @Test("strokeCancelled defaults to strokeEnded for legacy conformers")
    func cancelDefaultsToEnded() {
        // A conformer written before strokeCancelled existed (task 3.1)
        // still closes its stroke when the capture side aborts one.
        struct LegacyProbe: StrokeConsumer {
            var events: [String] = []
            mutating func strokeBegan() { events.append("began") }
            mutating func consume(_ sample: StrokeSample) { events.append("sample") }
            mutating func strokeEnded() { events.append("ended") }
        }
        var probe = LegacyProbe()
        probe.strokeBegan()
        probe.strokeCancelled()
        #expect(probe.events == ["began", "ended"])

        // A consumer that overrides it (the recognizer discards aborted
        // strokes) sees the cancellation as its own event.
        struct CancelAwareProbe: StrokeConsumer {
            var events: [String] = []
            mutating func strokeBegan() { events.append("began") }
            mutating func consume(_ sample: StrokeSample) { events.append("sample") }
            mutating func strokeEnded() { events.append("ended") }
            mutating func strokeCancelled() { events.append("cancelled") }
        }
        var aware = CancelAwareProbe()
        aware.strokeBegan()
        aware.strokeCancelled()
        #expect(aware.events == ["began", "cancelled"])
    }
}

@Suite("Golden files")
struct GoldenFileTests {
    private func temporaryGoldenURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("golden-\(UUID().uuidString).bin")
    }

    @Test("matching data passes, mismatch reports the first differing byte")
    func dataComparison() throws {
        let url = temporaryGoldenURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([1, 2, 3]).write(to: url)

        try GoldenFile.compare(Data([1, 2, 3]), golden: url, regenerate: false)

        #expect(throws: GoldenFile.Failure.dataMismatch(
            path: url.path, firstDifference: 1, actualSize: 3, goldenSize: 3
        )) {
            try GoldenFile.compare(Data([1, 9, 3]), golden: url, regenerate: false)
        }
    }

    @Test("missing golden is an explicit failure, not a silent pass")
    func missingGolden() {
        let url = temporaryGoldenURL()
        #expect(throws: GoldenFile.Failure.missingGolden(path: url.path)) {
            try GoldenFile.compare(Data([1]), golden: url, regenerate: false)
        }
    }

    @Test("float comparison honors tolerance and count")
    func floatComparison() throws {
        let url = temporaryGoldenURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try GoldenFile.encode([1.0, 2.0, 3.0]).write(to: url)

        try GoldenFile.compare([1.0, 2.0, 3.0], golden: url, regenerate: false)
        try GoldenFile.compare([1.0, 2.0005, 3.0], golden: url, tolerance: 0.001, regenerate: false)

        #expect(throws: GoldenFile.Failure.self) {
            try GoldenFile.compare([1.0, 2.5, 3.0], golden: url, tolerance: 0.001, regenerate: false)
        }
        #expect(throws: GoldenFile.Failure.countMismatch(
            path: url.path, actualCount: 2, goldenCount: 3
        )) {
            try GoldenFile.compare([1.0, 2.0], golden: url, regenerate: false)
        }
    }

    @Test("float encode/decode round-trips bit patterns")
    func floatCodec() {
        let values: [Float] = [0, -0, 1.5, -.pi, .ulpOfOne, .greatestFiniteMagnitude]
        let decoded = GoldenFile.decode(GoldenFile.encode(values))
        #expect(decoded.count == values.count)
        for (a, b) in zip(values, decoded) {
            #expect(a.bitPattern == b.bitPattern)
        }
    }
}

@Suite("Engine golden regressions")
struct EngineGoldenTests {
    /// Goldens live next to the tests, versioned with the code.
    private var goldensDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Goldens", isDirectory: true)
    }

    /// First real golden (task 1.1b): the engine's payload serialization of
    /// the colored-cube fixture must stay bit-identical. Catches silent
    /// changes to the engine's OBJ writer, float formatting, or vertex/face
    /// ordering — exactly the class of drift the determinism spec forbids.
    /// Regenerate deliberately with REGEN_GOLDENS=1 after an intended
    /// engine change.
    @Test("colored-cube payload serialization is bit-stable")
    func cubePayloadGolden() throws {
        let fixture = try #require(Bundle.module.url(
            forResource: "cube_colored", withExtension: "obj", subdirectory: "Fixtures"
        ))
        let payload = try Mesh.loadOBJ(at: fixture).payloadData()
        try GoldenFile.compare(
            payload, golden: goldensDirectory.appendingPathComponent("cube_colored.payload.golden")
        )
    }

    /// Same golden discipline for derived geometry: compacted positions.
    @Test("colored-cube positions are bit-stable")
    func cubePositionsGolden() throws {
        let fixture = try #require(Bundle.module.url(
            forResource: "cube_colored", withExtension: "obj", subdirectory: "Fixtures"
        ))
        let positions = try Mesh.loadOBJ(at: fixture).positions()
        #expect(positions.count == 24)
        try GoldenFile.compare(
            positions,
            golden: goldensDirectory.appendingPathComponent("cube_colored.positions.golden")
        )
    }
}

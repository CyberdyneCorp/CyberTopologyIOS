import CyberKit
import Testing
@testable import CyberTopology

/// Perf-harness probe tests (task 2.2). Timing *thresholds* belong to the
/// device-only `ViewportPerfTests`; here we verify the measurement machinery
/// itself works everywhere, including on simulator.
struct FrameTimeProbeTests {
    @Test func statisticsAreNilBeforeAnySample() {
        #expect(FrameTimeProbe().statistics() == nil)
    }

    @Test func recordAggregatesAverageAndMax() throws {
        let probe = FrameTimeProbe()
        probe.record(seconds: 0.010)
        probe.record(seconds: 0.020)
        probe.record(seconds: 0.030)
        let stats = try #require(probe.statistics())
        #expect(stats.sampleCount == 3)
        #expect(abs(stats.averageSeconds - 0.020) < 1e-9)
        #expect(stats.maxSeconds == 0.030)
    }

    @Test func ringBufferCapsSampleCount() throws {
        let probe = FrameTimeProbe()
        for i in 0..<(FrameTimeProbe.capacity + 25) {
            probe.record(seconds: Double(i))
        }
        let stats = try #require(probe.statistics())
        #expect(stats.sampleCount == FrameTimeProbe.capacity)
        // The newest sample must have displaced the oldest.
        #expect(stats.maxSeconds == Double(FrameTimeProbe.capacity + 24))
    }

    @Test func resetDropsSamples() {
        let probe = FrameTimeProbe()
        probe.record(seconds: 0.016)
        probe.reset()
        #expect(probe.statistics() == nil)
    }

    /// End-to-end: a rendered frame must produce a probe sample (GPU or
    /// fallback wall-clock timing — the simulator reports no GPU
    /// timestamps). Completion handlers run asynchronously, so poll.
    @MainActor
    @Test func offscreenRenderRecordsFrameSample() async throws {
        let renderer = try #require(ViewportRenderer(), "Metal unavailable")
        renderer.load(mesh: try Mesh.loadOBJ(at: UITestSupport.writeSeedOBJ()))
        #expect(renderer.renderOffscreen(width: 64, height: 64) != nil)

        var stats: FrameTimeProbe.Statistics?
        for _ in 0..<200 {  // ≤ 2 s
            stats = renderer.frameProbe.statistics()
            if stats != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let recorded = try #require(stats, "no frame sample within 2 s")
        #expect(recorded.sampleCount >= 1)
        #expect(recorded.maxSeconds >= 0)
    }
}

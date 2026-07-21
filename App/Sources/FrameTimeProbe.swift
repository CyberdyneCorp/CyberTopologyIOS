import Metal
import QuartzCore
import os

/// Measurable render-time probe (task 2.2 perf harness).
///
/// Every command buffer routed through `attach(to:)` produces:
///
///  * an `os_signpost` interval ("frame") in the
///    `com.cyberdynecorp.cybertopology / viewport` category — visible in
///    Instruments' signpost track for on-device profiling sessions;
///  * a frame-duration sample kept in a fixed-capacity ring, preferring the
///    GPU timestamps (`gpuStartTime`/`gpuEndTime`), then the kernel
///    timestamps, then wall clock (the simulator reports zero GPU time).
///
/// The device-only performance XCTest asserts on `statistics()`; the
/// signpost side needs no assertions — it is the Instruments hook.
///
/// Thread-safety: Metal invokes completion handlers on its own completion
/// threads, so all mutable state sits behind a lock (`@unchecked Sendable`
/// by lock discipline).
final class FrameTimeProbe: @unchecked Sendable {
    struct Statistics: Equatable {
        var sampleCount: Int
        var averageSeconds: Double
        var maxSeconds: Double
    }

    /// Ring capacity: ~2 s of samples at 120 Hz.
    static let capacity = 240

    private let signposter = OSSignposter(
        subsystem: "com.cyberdynecorp.cybertopology", category: "viewport"
    )
    private let lock = NSLock()
    private var ring: [Double] = []
    private var nextSlot = 0

    /// Instruments the command buffer. Must be called before `commit()`.
    func attach(to commandBuffer: MTLCommandBuffer) {
        let interval = signposter.beginInterval("frame")
        let submitted = CACurrentMediaTime()
        commandBuffer.addCompletedHandler { [weak self] completed in
            guard let self else { return }
            self.signposter.endInterval("frame", interval)
            let gpu = completed.gpuEndTime - completed.gpuStartTime
            let kernel = completed.kernelEndTime - completed.kernelStartTime
            let wall = CACurrentMediaTime() - submitted
            self.record(seconds: gpu > 0 ? gpu : (kernel > 0 ? kernel : wall))
        }
    }

    /// Records one frame duration (internal so tests can drive the ring
    /// without a GPU).
    func record(seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        if ring.count < Self.capacity {
            ring.append(seconds)
        } else {
            ring[nextSlot] = seconds
        }
        nextSlot = (nextSlot + 1) % Self.capacity
    }

    /// Aggregate over the retained samples; nil before any frame completed.
    func statistics() -> Statistics? {
        lock.lock()
        defer { lock.unlock() }
        guard !ring.isEmpty else { return nil }
        return Statistics(
            sampleCount: ring.count,
            averageSeconds: ring.reduce(0, +) / Double(ring.count),
            maxSeconds: ring.max() ?? 0
        )
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        ring.removeAll(keepingCapacity: true)
        nextSlot = 0
    }
}

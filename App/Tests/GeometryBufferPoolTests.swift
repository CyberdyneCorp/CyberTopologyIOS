import Metal
import Testing
@testable import CyberTopology

/// Buffer-pool contract tests (task 2.2 "large-mesh handling"): allocation
/// reuse, headroom growth, and both storage strategies — including the
/// private-storage staging-blit path, forced on simulator so it stays
/// covered even though all iOS hardware is unified-memory.
@MainActor
struct GeometryBufferPoolTests {
    private func makePool(private usePrivate: Bool = false) throws -> GeometryBufferPool {
        let device = try #require(MTLCreateSystemDefaultDevice(), "Metal unavailable")
        let queue = try #require(device.makeCommandQueue())
        return GeometryBufferPool(
            device: device, commandQueue: queue, preferPrivateStorage: usePrivate
        )
    }

    private func upload(_ values: [Float], to pool: GeometryBufferPool) -> MTLBuffer? {
        values.withUnsafeBufferPointer { pool.upload(floats: $0, to: .position) }
    }

    @Test func sharedUploadStoresBytes() throws {
        let pool = try makePool()
        let values: [Float] = [1, 2, 3, 4.5]
        let buffer = try #require(upload(values, to: pool))
        #expect(!pool.usesPrivateStorage)
        #expect(pool.usedLength(for: .position) == values.count * 4)
        let stored = buffer.contents().bindMemory(to: Float.self, capacity: values.count)
        #expect(Array(UnsafeBufferPointer(start: stored, count: values.count)) == values)
    }

    @Test func sameSizeReloadReusesAllocation() throws {
        let pool = try makePool()
        _ = upload([1, 2, 3], to: pool)
        let allocations = pool.allocationCount
        _ = upload([4, 5, 6], to: pool)
        _ = upload([7, 8, 9], to: pool)
        #expect(pool.allocationCount == allocations)
    }

    /// Regression (shared-storage CPU-write vs in-flight GPU-read race):
    /// overwriting a REUSED shared buffer must first fence against the
    /// command queue; a fresh allocation cannot be referenced by any
    /// committed frame and must skip the wait.
    @Test func sharedReuseFencesAgainstInFlightFrames() throws {
        let pool = try makePool()
        _ = upload([1, 2, 3], to: pool)
        #expect(pool.reuseSynchronizations == 0)  // fresh allocation: no fence

        _ = upload([4, 5, 6], to: pool)  // same-size reload reuses the buffer
        #expect(pool.reuseSynchronizations == 1)

        // Growth reallocates: the new buffer needs no fence.
        _ = upload([Float](repeating: 0, count: 64), to: pool)
        #expect(pool.reuseSynchronizations == 1)

        // Reuse within the grown capacity fences again.
        _ = upload([Float](repeating: 0, count: 32), to: pool)
        #expect(pool.reuseSynchronizations == 2)

        // Empty uploads never fence.
        _ = upload([], to: pool)
        #expect(pool.reuseSynchronizations == 2)
    }

    /// The private-storage path is ordered by same-queue blits and must not
    /// pay the shared-path fence.
    @Test func privateStorageReuseDoesNotFence() throws {
        let pool = try makePool(private: true)
        _ = upload([1, 2, 3], to: pool)
        _ = upload([4, 5, 6], to: pool)
        #expect(pool.reuseSynchronizations == 0)
    }

    @Test func growthAddsHeadroomAndReusesWithinIt() throws {
        let pool = try makePool()
        _ = upload([Float](repeating: 0, count: 100), to: pool)  // 400 B
        #expect(pool.allocationCount == 1)

        // 480 B outgrows 400 B; capacity grows to max(480, 400 * 1.5) = 600.
        _ = upload([Float](repeating: 0, count: 120), to: pool)
        #expect(pool.allocationCount == 2)
        #expect(pool.capacity(for: .position) == 600)

        // 560 B fits inside the 600 B headroom: no new allocation.
        _ = upload([Float](repeating: 0, count: 140), to: pool)
        #expect(pool.allocationCount == 2)
    }

    @Test func emptyUploadClearsStream() throws {
        let pool = try makePool()
        _ = upload([1, 2, 3], to: pool)
        let result = upload([], to: pool)
        #expect(result == nil)
        #expect(pool.buffer(for: .position) == nil)
        #expect(pool.usedLength(for: .position) == 0)
    }

    @Test func streamsAreIndependent() throws {
        let pool = try makePool()
        _ = upload([1, 2, 3], to: pool)
        let indices: [UInt32] = [0, 1, 2]
        _ = indices.withUnsafeBufferPointer { pool.upload(indices: $0) }
        #expect(pool.buffer(for: .position) != nil)
        #expect(pool.buffer(for: .index) != nil)
        #expect(pool.buffer(for: .normal) == nil)
    }

    @Test func clearKeepsAllocationsForReuse() throws {
        let pool = try makePool()
        _ = upload([1, 2, 3], to: pool)
        let allocations = pool.allocationCount
        let capacity = pool.capacity(for: .position)

        pool.clear()
        #expect(pool.buffer(for: .position) == nil)
        #expect(pool.capacity(for: .position) == capacity)

        _ = upload([9, 9, 9], to: pool)
        #expect(pool.allocationCount == allocations)  // reload was free
    }

    @Test func releaseAllDropsAllocations() throws {
        let pool = try makePool()
        _ = upload([1, 2, 3], to: pool)
        pool.releaseAll()
        #expect(pool.capacity(for: .position) == 0)
        #expect(pool.buffer(for: .position) == nil)
    }

    /// Private-storage path: bytes must arrive intact in the `.private`
    /// buffer (verified by blitting them back into shared memory).
    @Test func privateStorageUploadRoundTrips() throws {
        let pool = try makePool(private: true)
        #expect(pool.usesPrivateStorage)
        let values: [Float] = [10, 20, 30, 40, 50]
        let buffer = try #require(upload(values, to: pool))
        #expect(buffer.storageMode == .private)

        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let byteCount = values.count * 4
        let readback = try #require(device.makeBuffer(length: byteCount))
        let commandBuffer = try #require(queue.makeCommandBuffer())
        let blit = try #require(commandBuffer.makeBlitCommandEncoder())
        blit.copy(from: buffer, sourceOffset: 0, to: readback, destinationOffset: 0, size: byteCount)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let stored = readback.contents().bindMemory(to: Float.self, capacity: values.count)
        #expect(Array(UnsafeBufferPointer(start: stored, count: values.count)) == values)
    }

    @Test func privateStorageReusesStagingBuffer() throws {
        let pool = try makePool(private: true)
        _ = upload([1, 2, 3], to: pool)
        // First upload allocates the slot and the staging buffer.
        #expect(pool.allocationCount == 2)
        _ = upload([4, 5, 6], to: pool)
        #expect(pool.allocationCount == 2)  // both reused
    }
}

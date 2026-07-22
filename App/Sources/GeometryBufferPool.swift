import Metal

/// GPU buffer pool for target geometry (task 2.2 "large-mesh handling").
///
/// Memory strategy — documented here because it is a contract, not an
/// implementation detail:
///
///  * Each geometry stream (positions / normals / colors / indices) owns one
///    pooled `MTLBuffer` slot that is **reused across mesh loads**. A reload
///    reallocates only when the incoming data outgrows the slot's capacity,
///    and growth adds 50% headroom (`growthFactor`) so a sequence of
///    slightly-larger loads costs O(log n) allocations, not O(n).
///  * **Nothing allocates per frame.** Uploads happen at mesh-load time
///    only; `buffer(for:)` returns existing allocations for the render path
///    to bind. `allocationCount` exists so tests can enforce this.
///    Live brush edits (task 3.3) reload geometry repeatedly, but the
///    viewport coalesces those to AT MOST ONE upload per rendered frame
///    (`ViewportRenderer.pendingGeometryRefresh`) — never per input
///    sample; `uploadCount` exists so tests can enforce that too.
///  * **Storage mode:** every iOS/iPadOS device and the simulator has
///    unified memory, where `.storageModeShared` is already GPU-optimal —
///    the GPU reads the very pages the CPU wrote (no blit, no second copy).
///    Writing into a *reused* shared buffer first drains the command queue
///    (`drainQueue`): a frame committed moments earlier may still be
///    reading that buffer, and CPU writes are not hazard-tracked.
///    With `preferPrivateStorage` (non-unified-memory hardware; tests force
///    it on simulator to keep the path honest) geometry lives in
///    `.storageModePrivate` buffers filled through one reusable shared
///    staging buffer + blit, so the GPU keeps large meshes in dedicated
///    memory. The blit waits for completion — acceptable because it is a
///    load-time cost, never a frame-time one.
///  * Shrinking is deliberate-only (`releaseAll`): closing a big document
///    returns memory, while transient reloads never thrash the allocator.
@MainActor
final class GeometryBufferPool {
    enum Stream: CaseIterable {
        case position
        case normal
        case color
        case index
    }

    /// Capacity headroom applied when a slot must grow.
    static let growthFactor = 1.5

    private struct Slot {
        var buffer: MTLBuffer
        /// Bytes of the current mesh actually stored (≤ buffer.length).
        var usedLength: Int
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    /// True when geometry lives in private storage behind staging blits.
    let usesPrivateStorage: Bool
    private var slots: [Stream: Slot] = [:]
    /// Reusable staging buffer for the private-storage upload path.
    private var staging: MTLBuffer?

    /// Total `MTLBuffer` allocations ever made by this pool (staging
    /// included). Tests assert the no-per-frame-reallocation contract by
    /// checking this stays flat across same-size reloads and draws.
    private(set) var allocationCount = 0

    /// Times the shared-storage path drained the queue before overwriting a
    /// reused buffer (CPU-write vs in-flight-GPU-read fence). Tests assert
    /// the fence fires exactly on reuse, never on fresh allocations.
    private(set) var reuseSynchronizations = 0

    /// Successful stream uploads ever performed. Tests assert the live-edit
    /// coalescing contract with it: N brush samples between two frames cost
    /// one geometry load (one upload per stream), not N.
    private(set) var uploadCount = 0

    init(device: MTLDevice, commandQueue: MTLCommandQueue, preferPrivateStorage: Bool) {
        self.device = device
        self.commandQueue = commandQueue
        self.usesPrivateStorage = preferPrivateStorage
    }

    // MARK: - Uploads (load-time only)

    /// Uploads a float stream; returns the pooled buffer or nil on empty
    /// input / allocation failure.
    @discardableResult
    func upload(floats: UnsafeBufferPointer<Float>, to stream: Stream) -> MTLBuffer? {
        upload(UnsafeRawBufferPointer(floats), to: stream)
    }

    /// Uploads the triangle index stream.
    @discardableResult
    func upload(indices: UnsafeBufferPointer<UInt32>) -> MTLBuffer? {
        upload(UnsafeRawBufferPointer(indices), to: .index)
    }

    @discardableResult
    func upload(_ bytes: UnsafeRawBufferPointer, to stream: Stream) -> MTLBuffer? {
        guard let base = bytes.baseAddress, !bytes.isEmpty else {
            slots[stream]?.usedLength = 0
            return nil
        }
        guard let (buffer, reused) = reserve(byteCount: bytes.count, for: stream) else {
            return nil
        }
        if usesPrivateStorage {
            guard blit(base, byteCount: bytes.count, into: buffer) else {
                slots[stream]?.usedLength = 0
                return nil
            }
        } else {
            // A reused shared buffer may still be bound by a frame in flight
            // on the same queue (e.g. undo/redo swapping to a same-size mesh
            // one frame after a draw). GPU reads and this CPU write are not
            // hazard-tracked against each other, so drain the queue before
            // overwriting. Load-time cost only — a fresh allocation cannot
            // be referenced by any committed frame and skips the wait.
            if reused { drainQueue() }
            buffer.contents().copyMemory(from: base, byteCount: bytes.count)
        }
        uploadCount += 1
        return buffer
    }

    // MARK: - Frame-time access (never allocates)

    /// The pooled buffer currently holding `stream` data, or nil when the
    /// stream is empty/cleared.
    func buffer(for stream: Stream) -> MTLBuffer? {
        guard let slot = slots[stream], slot.usedLength > 0 else { return nil }
        return slot.buffer
    }

    /// Bytes of live data in `stream` (0 when cleared).
    func usedLength(for stream: Stream) -> Int {
        slots[stream]?.usedLength ?? 0
    }

    /// Allocated capacity of the stream's slot in bytes.
    func capacity(for stream: Stream) -> Int {
        slots[stream]?.buffer.length ?? 0
    }

    // MARK: - Lifecycle

    /// Marks all streams empty but keeps the allocations for the next load
    /// (reload of a similarly sized mesh costs zero allocations).
    func clear() {
        for stream in slots.keys {
            slots[stream]?.usedLength = 0
        }
    }

    /// Drops every allocation (document closed / memory pressure).
    func releaseAll() {
        slots.removeAll()
        staging = nil
    }

    // MARK: - Internals

    /// Returns a buffer with at least `byteCount` capacity for `stream`,
    /// reusing the existing allocation whenever it is large enough.
    /// `reused` is true when the returned buffer may already be referenced
    /// by previously committed GPU work (the caller must order against it).
    private func reserve(
        byteCount: Int, for stream: Stream
    ) -> (buffer: MTLBuffer, reused: Bool)? {
        if var slot = slots[stream], slot.buffer.length >= byteCount {
            slot.usedLength = byteCount
            slots[stream] = slot
            return (slot.buffer, true)
        }
        let capacity = grownCapacity(current: slots[stream]?.buffer.length ?? 0, needed: byteCount)
        let options: MTLResourceOptions =
            usesPrivateStorage ? .storageModePrivate : .storageModeShared
        guard let buffer = device.makeBuffer(length: capacity, options: options) else {
            return nil
        }
        buffer.label = "geometry-pool-\(stream)"
        allocationCount += 1
        slots[stream] = Slot(buffer: buffer, usedLength: byteCount)
        return (buffer, false)
    }

    /// Blocks until every previously committed command buffer on the shared
    /// queue (including in-flight frames binding pooled buffers) completed.
    /// Same-queue ordering makes an empty command buffer a full barrier.
    private func drainQueue() {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        commandBuffer.label = "geometry-pool-reuse-fence"
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        reuseSynchronizations += 1
    }

    private func grownCapacity(current: Int, needed: Int) -> Int {
        max(needed, Int(Double(current) * Self.growthFactor))
    }

    /// Copies CPU bytes into a private-storage buffer through the reusable
    /// shared staging buffer. Synchronous by design (load-time only).
    private func blit(_ base: UnsafeRawPointer, byteCount: Int, into destination: MTLBuffer) -> Bool {
        if staging == nil || staging!.length < byteCount {
            let capacity = grownCapacity(current: staging?.length ?? 0, needed: byteCount)
            staging = device.makeBuffer(length: capacity, options: .storageModeShared)
            guard staging != nil else { return false }
            staging!.label = "geometry-pool-staging"
            allocationCount += 1
        }
        guard
            let staging,
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeBlitCommandEncoder()
        else { return false }
        staging.contents().copyMemory(from: base, byteCount: byteCount)
        encoder.copy(
            from: staging, sourceOffset: 0,
            to: destination, destinationOffset: 0, size: byteCount
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return commandBuffer.status == .completed
    }
}

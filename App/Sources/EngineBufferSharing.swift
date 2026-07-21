import Foundation

/// Decision logic for sharing engine-owned CPU geometry with Metal
/// (task 2.4, design D2: the engine owns geometry buffers and exposes them
/// zero-copy over unified memory — solver ghosts render with no readback).
///
/// `MTLDevice.makeBuffer(bytesNoCopy:)` can wrap existing memory only when
/// the base address is page-aligned and the length is a whole multiple of
/// the page size, and it only *pays off* on unified-memory hardware (where
/// `.storageModeShared` is already GPU-optimal). Anything else takes one
/// memcpy into a pooled `GeometryBufferPool` buffer — still no GPU readback,
/// just a single load-time CPU copy.
///
/// Additional precondition the decision cannot see from a pointer: the
/// wrapped memory must be VM-allocated (`vm_allocate`/`mmap`), per the
/// `makeBuffer(bytesNoCopy:)` documentation — page-aligned `malloc` memory
/// traps (the simulator backs no-copy buffers with XPC shared memory over
/// the VM region). Callers only pass `allowZeroCopy` for memory whose
/// allocator honors that contract.
///
/// Known limitation (upstream): the engine's render caches are `malloc`ed
/// `std::vector` storage sized to content, so they satisfy neither the page
/// constraints nor the VM-allocation contract, and the pooled-copy branch
/// is what actually runs today. Fixing that needs page-aligned, page-padded
/// VM allocations engine-side (CyberRemesherAndUV issue; a future numbered
/// patch in `Engine/patches/`). The decision below is deliberately per-load
/// so qualifying engine buffers start zero-copy sharing with no app changes
/// the day the upstream allocation lands.
///
/// Lifetime contract for the zero-copy branch: a `bytesNoCopy` buffer
/// aliases the engine mesh's memory and MUST NOT outlive the `Mesh` (nor
/// survive any mutation of it). Whoever wraps engine pointers keeps the
/// `Mesh` reference alive for as long as the `MTLBuffer` is bound — see
/// `ViewportRenderer.ghostSourceMesh`.
enum EngineBufferSharing {
    /// Whether the engine's render caches honor the full
    /// `makeBuffer(bytesNoCopy:)` allocation contract (VM-allocated via
    /// `vm_allocate`/`mmap`, page-aligned, page-padded).
    ///
    /// **False today**: the caches are `malloc`ed `std::vector` storage.
    /// The page-alignment/size decision below cannot detect the allocator
    /// from a pointer, and Darwin's large-zone `malloc` returns page-aligned
    /// storage — so a coincidentally qualifying buffer would take the
    /// zero-copy branch and trap inside Metal. Callers wrapping engine
    /// render caches MUST gate `allowZeroCopy` on this flag. Flip it to
    /// true only when the upstream page-aligned VM-allocation patch lands
    /// in `Engine/patches/` (CyberRemesherAndUV issue); the rest of the
    /// zero-copy machinery is already in place and tested against
    /// `mmap`-backed fixtures.
    static let engineRenderCachesAreVMAllocated = false

    /// Which upload path a buffer takes into GPU-visible memory.
    enum Path: String, Equatable, Sendable {
        /// Wrap the engine pointer directly via `makeBuffer(bytesNoCopy:)`.
        case zeroCopy = "zero-copy"
        /// One memcpy into a pooled shared/private buffer.
        case pooledCopy = "pooled-copy"
    }

    /// Pure decision for a single buffer. `baseAddress` is the pointer's bit
    /// pattern (`UInt(bitPattern:)`) so the function is testable without
    /// fabricating real pointers.
    static func path(
        baseAddress: UInt, byteCount: Int, hasUnifiedMemory: Bool, pageSize: Int
    ) -> Path {
        guard
            hasUnifiedMemory,
            pageSize > 0,
            baseAddress != 0,
            byteCount > 0,
            baseAddress.isMultiple(of: UInt(pageSize)),
            byteCount.isMultiple(of: pageSize)
        else { return .pooledCopy }
        return .zeroCopy
    }

    /// Aggregate decision for one mesh's streams: zero-copy only when every
    /// stream qualifies. Mixing paths within one mesh would split the
    /// lifetime contract (some buffers aliasing the mesh, some not) for no
    /// measurable win, so it is all-or-nothing by design.
    static func path(
        streams: [(baseAddress: UInt, byteCount: Int)],
        hasUnifiedMemory: Bool,
        pageSize: Int
    ) -> Path {
        guard !streams.isEmpty else { return .pooledCopy }
        let allQualify = streams.allSatisfy {
            path(
                baseAddress: $0.baseAddress, byteCount: $0.byteCount,
                hasUnifiedMemory: hasUnifiedMemory, pageSize: pageSize
            ) == .zeroCopy
        }
        return allQualify ? .zeroCopy : .pooledCopy
    }
}

import Foundation
import Metal
import os
import simd

// Ghost geometry pipeline (task 2.4, spec: viewport-rendering / "Ghost
// geometry rendering", design D2: dedicated overlay pipeline for
// EditMesh/ghosts — the "feel" is a first-class deliverable).
//
// Solver proposals (Weave results, auto-seam proposals, autocomplete
// patches) render as translucent, pulsing surfaces clearly distinct from
// the committed EditMesh wireframe: filled amber triangles with a rim tint
// and a time-driven alpha pulse versus the overlay's cyan line list. Like
// the overlay's creation animation, the pulse is a pure time→value mapping
// fed through one uniform per frame — no geometry churn.
//
// Geometry arrives from the engine either zero-copy (unified memory +
// page-aligned buffers wrapped via `makeBuffer(bytesNoCopy:)`) or through
// one memcpy into a pooled buffer — see `EngineBufferSharing` for the
// decision and its lifetime contract. Which path ran is recorded in
// `activeSharing` and logged.

/// Visual parameters for ghost (proposed) geometry. Pure math, unit-tested
/// without Metal.
struct GhostStyle: Equatable {
    /// Default proposal style: translucent amber, clearly distinct from the
    /// committed wireframe's cyan (`OverlayUniformsFactory.wireColor`).
    static let proposal = GhostStyle()

    /// Ghost tint (linear RGB).
    var color = SIMD3<Float>(1.0, 0.62, 0.24)
    /// Peak opacity of the pulse.
    var baseAlpha: Float = 0.55
    /// Pulse period in seconds.
    var pulsePeriod: Double = 1.4
    /// Fraction of `baseAlpha` at the pulse trough (never fully invisible).
    var pulseFloor: Float = 0.45
    /// Rim tint strength (0 disables the rim highlight).
    var rimStrength: Float = 0.65
    /// Displacement along the vertex normal in world units (used by the
    /// debug preview so a ghost of the committed EditMesh hovers above it).
    var normalOffset: Float = 0

    /// Pulsing opacity at `time` (a monotone clock like CACurrentMediaTime):
    /// sinusoidal between `baseAlpha * pulseFloor` and `baseAlpha`.
    func pulsedAlpha(at time: Double) -> Float {
        guard pulsePeriod > 0 else { return baseAlpha }
        let wave = Float(0.5 * (1 + sin(2 * .pi * time / pulsePeriod)))
        return baseAlpha * (pulseFloor + (1 - pulseFloor) * wave)
    }

    /// Time offset (within one period) of the pulse peak / trough — lets
    /// tests sample maximally different frames deterministically.
    var pulsePeakPhase: Double { pulsePeriod * 0.25 }
    var pulseTroughPhase: Double { pulsePeriod * 0.75 }

    /// DEBUG-only demo style (task 2.4): until the Weave solver exists
    /// (phase 5) the viewport-settings popover can render the committed
    /// EditMesh as a ghost, lifted off the surface by a small fraction of
    /// the scene radius so both styles are visible at once.
    static func debugPreview(sceneRadius: Float) -> GhostStyle {
        var style = GhostStyle.proposal
        style.normalOffset = max(sceneRadius, 1e-6) * 0.02
        return style
    }
}

/// Per-draw ghost uniforms. Layout must match the MSL `GhostUniforms`
/// struct: float4x4 then three float4s.
struct GhostUniforms: Equatable {
    var mvp: simd_float4x4
    /// Tint (rgb) and pulsed opacity (a).
    var color: SIMD4<Float>
    /// x: normal offset (world units), y: rim strength, z,w: reserved.
    var params: SIMD4<Float>
    /// Camera forward direction (world space), w unused.
    var viewDir: SIMD4<Float>
}

/// Pure uniform construction, unit-tested without a GPU.
enum GhostUniformsFactory {
    static func uniforms(
        mvp: simd_float4x4,
        viewDirection: SIMD3<Float>,
        style: GhostStyle,
        time: Double
    ) -> GhostUniforms {
        GhostUniforms(
            mvp: mvp,
            color: SIMD4(style.color, style.pulsedAlpha(at: time)),
            params: SIMD4(style.normalOffset, style.rimStrength, 0, 0),
            viewDir: SIMD4(viewDirection.x, viewDirection.y, viewDirection.z, 0)
        )
    }
}

/// Translucent triangle pipeline for proposed ("ghost") geometry:
/// alpha-blended fill with a rim tint, depth-tested against the Target
/// (compare ≤) with depth writes off so ghosts never disturb Target depth.
/// Rendered between the Target and the committed wireframe overlay, so
/// accepted topology always reads on top.
@MainActor
final class GhostRenderPath {
    private static let log = Logger(
        subsystem: "com.cyberdynecorp.cybertopology", category: "ghost-geometry"
    )

    let bufferPool: GeometryBufferPool
    private let device: MTLDevice
    /// The renderer's queue — shared with every frame submission, so an
    /// empty command buffer on it is a full ordering barrier against
    /// in-flight frames (same mechanism as `GeometryBufferPool.drainQueue`).
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState

    private(set) var indexCount = 0
    private(set) var vertexCount = 0
    /// Which upload path the current geometry took; nil when empty. Logged
    /// on every load (task 2.4: "log which path is active").
    private(set) var activeSharing: EngineBufferSharing.Path?
    /// `bytesNoCopy` wrappers aliasing engine memory when `activeSharing`
    /// is `.zeroCopy` — see `EngineBufferSharing` for the lifetime contract
    /// (the wrapped memory's owner must stay alive; the renderer retains
    /// the source `Mesh`). Dropping these wrappers is what releases the
    /// caller from that contract, so every transition away from zero-copy
    /// (`clear()`, any reload) first drains the command queue: a command
    /// buffer retains the `MTLBuffer` objects but — with `deallocator: nil`
    /// — not the memory they alias, so freeing the source mesh while a
    /// frame is still executing would be a GPU use-after-free.
    private var zeroCopyBuffers: [GeometryBufferPool.Stream: MTLBuffer] = [:]

    /// Times the queue was drained before releasing zero-copy wrappers
    /// (zeroCopy → clear / reload transitions). Tests assert the fence
    /// fires exactly on those transitions and never on pooled ones.
    private(set) var zeroCopyReleaseSynchronizations = 0

    var hasGeometry: Bool { indexCount > 0 }

    /// Fails only when the embedded shader does not compile or a pipeline/
    /// depth state cannot be built (programmer error, surfaced by tests).
    init?(device: MTLDevice, commandQueue: MTLCommandQueue, preferPrivateStorage: Bool) {
        guard let library = try? device.makeLibrary(source: Self.shaderSource, options: nil)
        else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "ghost-geometry"
        descriptor.vertexFunction = library.makeFunction(name: "ghost_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "ghost_fragment")
        descriptor.colorAttachments[0].pixelFormat = ViewportRenderer.colorPixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        descriptor.depthAttachmentPixelFormat = ViewportRenderer.depthPixelFormat

        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .lessEqual
        depth.isDepthWriteEnabled = false

        guard
            let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor),
            let depthState = device.makeDepthStencilState(descriptor: depth)
        else { return nil }

        self.device = device
        self.commandQueue = commandQueue
        self.pipelineState = pipeline
        self.depthState = depthState
        self.bufferPool = GeometryBufferPool(
            device: device, commandQueue: commandQueue,
            preferPrivateStorage: preferPrivateStorage
        )
    }

    /// Uploads ghost geometry (engine-compacted positions/normals +
    /// triangulated indices). `allowZeroCopy` must be true ONLY when BOTH
    /// hold: the memory is VM-allocated (`vm_allocate`/`mmap`) per the
    /// `makeBuffer(bytesNoCopy:)` contract — page-aligned `malloc` memory
    /// traps, and the page decision cannot detect the allocator — AND the
    /// caller keeps it alive for the lifetime of this geometry (e.g. the
    /// renderer retaining the source `Mesh`). Borrowed arrays, transient
    /// storage, and today's malloc-backed engine caches (gate it on
    /// `EngineBufferSharing.engineRenderCachesAreVMAllocated`) must pass
    /// false. Returns false and clears on undrawable input or allocation
    /// failure.
    @discardableResult
    func load(
        positions: UnsafeBufferPointer<Float>,
        normals: UnsafeBufferPointer<Float>,
        indices: UnsafeBufferPointer<UInt32>,
        hasUnifiedMemory: Bool,
        allowZeroCopy: Bool,
        pageSize: Int = Int(getpagesize())
    ) -> Bool {
        guard !positions.isEmpty, !normals.isEmpty, !indices.isEmpty else {
            clear()
            return false
        }
        let decision: EngineBufferSharing.Path =
            allowZeroCopy
            ? EngineBufferSharing.path(
                streams: [
                    (UInt(bitPattern: positions.baseAddress), positions.count * 4),
                    (UInt(bitPattern: normals.baseAddress), normals.count * 4),
                    (UInt(bitPattern: indices.baseAddress), indices.count * 4),
                ],
                hasUnifiedMemory: hasUnifiedMemory, pageSize: pageSize
            )
            : .pooledCopy

        // Any reload transitions away from the current wrappers (replaced
        // on the zero-copy branch, dropped on the pooled one): order the
        // release of the aliased engine memory after every in-flight frame.
        drainBeforeReleasingZeroCopyMemory()

        let loaded: Bool
        if decision == .zeroCopy, wrapZeroCopy(positions, normals, indices) {
            // Stale pooled data must never be bindable alongside wrappers.
            bufferPool.clear()
            activeSharing = .zeroCopy
            Self.log.info("ghost geometry sharing: zero-copy (bytesNoCopy wrap)")
            loaded = true
        } else {
            zeroCopyBuffers = [:]
            loaded = bufferPool.upload(floats: positions, to: .position) != nil
                && bufferPool.upload(floats: normals, to: .normal) != nil
                && bufferPool.upload(indices: indices) != nil
            activeSharing = loaded ? .pooledCopy : nil
            if loaded {
                let reason: String
                if !allowZeroCopy {
                    reason = "caller memory transient or not VM-allocated"
                } else if decision == .zeroCopy {
                    reason = "bytesNoCopy wrap failed"
                } else {
                    reason = "buffers not page-aligned/page-padded or memory not unified"
                }
                Self.log.info(
                    "ghost geometry sharing: pooled copy (\(reason, privacy: .public))"
                )
            }
        }
        guard loaded else {
            clear()
            return false
        }
        vertexCount = positions.count / 3
        indexCount = indices.count
        return true
    }

    func clear() {
        // The caller releases the wrapped memory's owner right after a
        // clear (e.g. `ViewportRenderer.clearGhost` dropping the source
        // mesh); fence against frames still reading the aliased pages.
        drainBeforeReleasingZeroCopyMemory()
        indexCount = 0
        vertexCount = 0
        activeSharing = nil
        zeroCopyBuffers = [:]
        bufferPool.clear()
    }

    /// Blocks until every committed command buffer on the shared queue
    /// completed — but only when zero-copy wrappers are live (pooled
    /// geometry is protected by `GeometryBufferPool.drainQueue` on reuse;
    /// fresh pooled loads need no fence). Load/clear-time cost only, and
    /// only on the zero-copy path, which is inactive in production until
    /// the engine's VM-allocation patch lands.
    private func drainBeforeReleasingZeroCopyMemory() {
        guard !zeroCopyBuffers.isEmpty else { return }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        commandBuffer.label = "ghost-zero-copy-release-fence"
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        zeroCopyReleaseSynchronizations += 1
    }

    /// Encodes the ghost fill over an already-encoded Target. Binds pooled
    /// or wrapped buffers only (never allocates at frame time).
    func encode(into encoder: MTLRenderCommandEncoder, uniforms: GhostUniforms) {
        guard
            hasGeometry,
            uniforms.color.w > 0,
            let positions = buffer(for: .position),
            let normals = buffer(for: .normal),
            let indices = buffer(for: .index)
        else { return }

        var uniforms = uniforms
        encoder.setRenderPipelineState(pipelineState)
        encoder.setDepthStencilState(depthState)
        encoder.setVertexBuffer(positions, offset: 0, index: 0)
        encoder.setVertexBuffer(normals, offset: 0, index: 1)
        encoder.setVertexBytes(
            &uniforms, length: MemoryLayout<GhostUniforms>.stride, index: 2
        )
        encoder.setFragmentBytes(
            &uniforms, length: MemoryLayout<GhostUniforms>.stride, index: 0
        )
        encoder.drawIndexedPrimitives(
            type: .triangle, indexCount: indexCount, indexType: .uint32,
            indexBuffer: indices, indexBufferOffset: 0
        )
    }

    // MARK: - Internals

    private func buffer(for stream: GeometryBufferPool.Stream) -> MTLBuffer? {
        zeroCopyBuffers[stream] ?? bufferPool.buffer(for: stream)
    }

    /// Wraps all three streams via `makeBuffer(bytesNoCopy:)`; all-or-nothing
    /// (mixed lifetimes are ruled out by the aggregate decision, and a
    /// partial wrap failure falls back to the pooled path).
    private func wrapZeroCopy(
        _ positions: UnsafeBufferPointer<Float>,
        _ normals: UnsafeBufferPointer<Float>,
        _ indices: UnsafeBufferPointer<UInt32>
    ) -> Bool {
        func wrap(_ base: UnsafeRawPointer?, byteCount: Int, label: String) -> MTLBuffer? {
            guard let base else { return nil }
            let buffer = device.makeBuffer(
                bytesNoCopy: UnsafeMutableRawPointer(mutating: base),
                length: byteCount,
                options: .storageModeShared,
                deallocator: nil  // engine/caller owns the memory
            )
            buffer?.label = "ghost-nocopy-\(label)"
            return buffer
        }
        guard
            let positionBuffer = wrap(
                positions.baseAddress, byteCount: positions.count * 4, label: "position"
            ),
            let normalBuffer = wrap(
                normals.baseAddress, byteCount: normals.count * 4, label: "normal"
            ),
            let indexBuffer = wrap(
                indices.baseAddress, byteCount: indices.count * 4, label: "index"
            )
        else { return false }
        zeroCopyBuffers = [
            .position: positionBuffer, .normal: normalBuffer, .index: indexBuffer,
        ]
        return true
    }

    // MARK: - Shader

    /// Translucent fill with rim tint. Compiled at runtime like the target
    /// and overlay pipelines (works identically in app bundle and tests).
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct GhostUniforms {
        float4x4 mvp;
        float4   color;   // rgb tint, a = pulsed opacity
        float4   params;  // x normal offset, y rim strength
        float4   viewDir; // camera forward, world space
    };

    struct GhostVertexOut {
        float4 position [[position]];
        float3 normal;
    };

    vertex GhostVertexOut ghost_vertex(
        uint vid [[vertex_id]],
        const device packed_float3* positions [[buffer(0)]],
        const device packed_float3* normals   [[buffer(1)]],
        constant GhostUniforms& u             [[buffer(2)]])
    {
        GhostVertexOut out;
        // Normal offset applied on the GPU: the shared engine buffers stay
        // untouched (zero-copy contract) and the offset costs one uniform.
        float3 p = float3(positions[vid]) + float3(normals[vid]) * u.params.x;
        out.position = u.mvp * float4(p, 1.0);
        out.normal = float3(normals[vid]);
        return out;
    }

    fragment float4 ghost_fragment(
        GhostVertexOut in [[stage_in]],
        constant GhostUniforms& u [[buffer(0)]])
    {
        float3 n = normalize(in.normal);
        // Rim tint toward white on silhouette-grazing normals (double-sided,
        // consistent with cull mode none).
        float facing = abs(dot(n, u.viewDir.xyz));
        float rim = pow(1.0 - facing, 2.0) * u.params.y;
        float3 rgb = mix(u.color.rgb, float3(1.0), saturate(rim));
        return float4(rgb, u.color.a);
    }
    """
}

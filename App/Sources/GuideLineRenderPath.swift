import Metal
import simd

/// Per-draw guide-line uniforms. Layout must match the MSL `GuideLineUniforms`
/// struct: a float4x4 then one float4.
struct GuideLineUniforms: Equatable {
    var mvp: simd_float4x4
    /// Solid line colour (rgb) and opacity (a).
    var color: SIMD4<Float>
    /// x: NDC occlusion depth bias (pulls the line slightly toward the camera
    /// so it sits on the surface it lies on instead of z-fighting it). y/z/w
    /// reserved.
    var params: SIMD4<Float>
}

/// Pure uniform construction, unit-tested without a GPU.
enum GuideLineUniformsFactory {
    static func uniforms(
        mvp: simd_float4x4, color: SIMD4<Float>, depthBias: Float
    ) -> GuideLineUniforms {
        GuideLineUniforms(mvp: mvp, color: color, params: SIMD4(depthBias, 0, 0, 0))
    }
}

/// Depth-tested amber line overlay for authored Weave guide strokes
/// (add-guide-stroke-authoring). World-space line segments drawn on top of the
/// Target: depth-tested (compare ≤) with depth writes off, a small occlusion
/// bias so they sit on the surface. Modelled on `GhostRenderPath`, minus the
/// normals, lighting, and zero-copy machinery — guide geometry is small,
/// app-generated, transient arrays, so it always takes the pooled copy path.
@MainActor
final class GuideLineRenderPath {
    let bufferPool: GeometryBufferPool
    private let pipelineState: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState

    private(set) var indexCount = 0
    private(set) var vertexCount = 0

    /// Amber, matching the Weave-proposal ghost so guides and their resulting
    /// cage read as one family.
    static let color = SIMD4<Float>(1.0, 0.62, 0.24, 0.95)

    var hasGeometry: Bool { indexCount > 0 }

    /// Fails only when the embedded shader does not compile or a pipeline /
    /// depth state cannot be built (programmer error, surfaced by tests).
    init?(device: MTLDevice, commandQueue: MTLCommandQueue, preferPrivateStorage: Bool) {
        guard let library = try? device.makeLibrary(source: Self.shaderSource, options: nil)
        else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "guide-lines"
        descriptor.vertexFunction = library.makeFunction(name: "guide_line_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "guide_line_fragment")
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

        self.pipelineState = pipeline
        self.depthState = depthState
        self.bufferPool = GeometryBufferPool(
            device: device, commandQueue: commandQueue,
            preferPrivateStorage: preferPrivateStorage
        )
    }

    /// Uploads line geometry: `positions` is x,y,z per vertex; `indices` are
    /// vertex-index PAIRS, one per segment (`[a,b, b,c, …]`). Empty input
    /// clears. Always a pooled copy (the arrays are transient).
    @discardableResult
    func load(positions: [Float], indices: [UInt32]) -> Bool {
        guard !positions.isEmpty, !indices.isEmpty else {
            clear()
            return false
        }
        let ok = positions.withUnsafeBufferPointer { pos -> Bool in
            indices.withUnsafeBufferPointer { idx -> Bool in
                bufferPool.upload(floats: pos, to: .position) != nil
                    && bufferPool.upload(indices: idx) != nil
            }
        }
        guard ok else {
            clear()
            return false
        }
        vertexCount = positions.count / 3
        indexCount = indices.count
        return true
    }

    func clear() {
        indexCount = 0
        vertexCount = 0
        bufferPool.clear()
    }

    /// Encodes the guide lines over an already-encoded Target.
    func encode(into encoder: MTLRenderCommandEncoder, uniforms: GuideLineUniforms) {
        guard
            hasGeometry, uniforms.color.w > 0,
            let positions = bufferPool.buffer(for: .position),
            let indices = bufferPool.buffer(for: .index)
        else { return }

        var uniforms = uniforms
        encoder.setRenderPipelineState(pipelineState)
        encoder.setDepthStencilState(depthState)
        encoder.setVertexBuffer(positions, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<GuideLineUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<GuideLineUniforms>.stride, index: 0)
        encoder.drawIndexedPrimitives(
            type: .line, indexCount: indexCount, indexType: .uint32,
            indexBuffer: indices, indexBufferOffset: 0
        )
    }

    // MARK: - Shader

    /// Solid line, depth-biased toward the camera. Compiled at runtime like the
    /// other pipelines (works identically in app bundle and tests).
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct GuideLineUniforms {
        float4x4 mvp;
        float4   color;   // rgb, a = opacity
        float4   params;  // x NDC occlusion depth bias
    };

    struct GuideVertexOut {
        float4 position [[position]];
    };

    vertex GuideVertexOut guide_line_vertex(
        uint vid [[vertex_id]],
        const device packed_float3* positions [[buffer(0)]],
        constant GuideLineUniforms& u         [[buffer(1)]])
    {
        GuideVertexOut out;
        float4 clip = u.mvp * float4(float3(positions[vid]), 1.0);
        // Pull toward the camera a touch so the line sits ON the surface it
        // lies on rather than z-fighting it (same NDC-bias trick the ghost
        // fill uses for occlusion).
        clip.z -= u.params.x * clip.w;
        out.position = clip;
        return out;
    }

    fragment float4 guide_line_fragment(
        GuideVertexOut in [[stage_in]],
        constant GuideLineUniforms& u [[buffer(0)]])
    {
        return float4(u.color.rgb, u.color.a);
    }
    """
}

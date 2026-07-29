import Metal
import simd

/// Per-draw checker uniforms. Layout must match the MSL `UVCheckerUniforms` struct.
struct UVCheckerUniforms: Equatable {
    var mvp: simd_float4x4
    /// x: checker squares across the unit UV square. y: opacity. z: shading strength.
    /// w: 1 to sample the imported texture, 0 for the procedural checker.
    var params: SIMD4<Float>
}

/// Checker appearance, held by the renderer so it survives frames.
struct UVCheckerSettings: Equatable {
    var density: Float = UVCheckerUniformsFactory.defaultDensity
    var opacity: Float = 1
    /// Sample an imported image instead of the procedural checker. Ignored when no image is loaded,
    /// so turning it on without one shows the checker rather than a blank surface.
    var usesImportedTexture = false
    /// 0 disables wrap shading, leaving the checker parity as the ONLY source of tone. Tests use
    /// that to assert the pattern itself rather than the lighting.
    var shading: Float = 0.35
}

/// Pure uniform construction, unit-tested without a GPU.
enum UVCheckerUniformsFactory {
    /// Checker squares across the unit UV square.
    ///
    /// A power of two so a tile boundary lands exactly on the UV grid lines an artist reasons about,
    /// and small enough that individual squares stay readable on a cage-scale shell rather than
    /// aliasing into grey.
    static let defaultDensity: Float = 16

    static func uniforms(
        mvp: simd_float4x4, density: Float = defaultDensity, opacity: Float = 1,
        shading: Float = 0.35, usesTexture: Bool = false
    ) -> UVCheckerUniforms {
        UVCheckerUniforms(
            mvp: mvp,
            // Density is clamped positive: a zero or negative density would collapse the checker to
            // a single colour and read as "the preview is broken" rather than "the UVs are wrong".
            params: SIMD4(
                max(density, 1), max(min(opacity, 1), 0), max(shading, 0),
                usesTexture ? 1 : 0
            )
        )
    }
}

/// Checker texture preview on the 3D surface (openspec add-uv-texture-preview, 6.3c).
///
/// The first textured render path in the app: nothing else samples a texture, and neither the Target
/// nor the overlay vertex stream carries UVs at all. Modelled on `GuideLineRenderPath` — runtime
/// shader compile, pooled buffers, depth-tested — with a UV attribute and a PROCEDURAL checker.
///
/// **Procedural rather than a sampled texture, deliberately.** A generated checker needs no asset,
/// no texture upload and no sampler state, and it is exactly what the preview is for: seeing where
/// UVs stretch, shear or flip. An IMPORTED image would additionally need asset loading and a real
/// texture, and it visualizes nothing a checker does not — so it is a separate concern rather than a
/// prerequisite.
@MainActor
final class UVCheckerRenderPath {
    let bufferPool: GeometryBufferPool
    private let pipelineState: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState

    private(set) var vertexCount = 0
    /// The imported preview image, when one is loaded.
    private(set) var importedTexture: MTLTexture?
    /// A 1×1 stand-in bound whenever no image is loaded.
    ///
    /// Metal requires a texture at every declared binding, so the shader cannot simply omit it when
    /// unused. A dummy keeps ONE pipeline for both modes rather than a second pipeline and a second
    /// shader that would drift from this one.
    private let placeholderTexture: MTLTexture
    private let samplerState: MTLSamplerState

    var hasGeometry: Bool { vertexCount > 0 }
    var hasImportedTexture: Bool { importedTexture != nil }

    /// Fails only when the embedded shader does not compile or a pipeline / depth state cannot be
    /// built (programmer error, surfaced by tests).
    init?(device: MTLDevice, commandQueue: MTLCommandQueue, preferPrivateStorage: Bool) {
        guard let library = try? device.makeLibrary(source: Self.shaderSource, options: nil)
        else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "uv-checker"
        descriptor.vertexFunction = library.makeFunction(name: "uv_checker_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "uv_checker_fragment")
        descriptor.colorAttachments[0].pixelFormat = ViewportRenderer.colorPixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        descriptor.depthAttachmentPixelFormat = ViewportRenderer.depthPixelFormat

        // Depth WRITES ON, unlike the line overlays: this is opaque surface shading, so a nearer
        // triangle must occlude a farther one or the checker would show through the model.
        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .lessEqual
        depth.isDepthWriteEnabled = true

        guard
            let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor),
            let depthState = device.makeDepthStencilState(descriptor: depth)
        else { return nil }

        // Repeat addressing, so UVs outside 0-1 tile rather than clamp: a UDIM layout deliberately
        // puts islands beyond the unit square, and clamping would smear the edge pixel across every
        // one of them.
        let sampler = MTLSamplerDescriptor()
        sampler.minFilter = .linear
        sampler.magFilter = .linear
        sampler.mipFilter = .linear
        sampler.sAddressMode = .repeat
        sampler.tAddressMode = .repeat
        let placeholder = MTLTextureDescriptor()
        placeholder.pixelFormat = .rgba8Unorm
        placeholder.width = 1
        placeholder.height = 1
        placeholder.usage = .shaderRead
        guard
            let samplerState = device.makeSamplerState(descriptor: sampler),
            let dummy = device.makeTexture(descriptor: placeholder)
        else { return nil }
        self.samplerState = samplerState
        self.placeholderTexture = dummy

        self.pipelineState = pipeline
        self.depthState = depthState
        self.bufferPool = GeometryBufferPool(
            device: device, commandQueue: commandQueue,
            preferPrivateStorage: preferPrivateStorage
        )
    }

    /// Uploads corner-expanded vertices. Empty input clears.
    ///
    /// Non-indexed by necessity — see `UVCheckerGeometry` for why UVs cannot ride a vertex-indexed
    /// stream without welding every seam shut.
    @discardableResult
    func load(vertices: [UVCheckerGeometry.Vertex]) -> Bool {
        guard !vertices.isEmpty else {
            clear()
            return false
        }
        // Flattened into one interleaved float stream: 3 position + 3 normal + 2 uv per vertex.
        var floats: [Float] = []
        floats.reserveCapacity(vertices.count * 8)
        for vertex in vertices {
            floats.append(vertex.position.x)
            floats.append(vertex.position.y)
            floats.append(vertex.position.z)
            floats.append(vertex.normal.x)
            floats.append(vertex.normal.y)
            floats.append(vertex.normal.z)
            floats.append(vertex.uv.x)
            floats.append(vertex.uv.y)
        }
        let ok = floats.withUnsafeBufferPointer { bufferPool.upload(floats: $0, to: .position) != nil }
        guard ok else {
            clear()
            return false
        }
        vertexCount = vertices.count
        return true
    }

    /// Sets (or clears) the imported preview image.
    func setImportedTexture(_ texture: MTLTexture?) {
        importedTexture = texture
    }

    func clear() {
        vertexCount = 0
        bufferPool.clear()
    }

    /// Encodes the checker surface.
    func encode(into encoder: MTLRenderCommandEncoder, uniforms: UVCheckerUniforms) {
        guard
            hasGeometry, uniforms.params.y > 0,
            let vertices = bufferPool.buffer(for: .position)
        else { return }

        var uniforms = uniforms
        // Falls back to the checker when the caller asked for a texture but none is loaded, rather
        // than sampling the 1×1 placeholder and painting the model one flat colour.
        if uniforms.params.w > 0, importedTexture == nil {
            uniforms.params.w = 0
        }
        encoder.setRenderPipelineState(pipelineState)
        encoder.setDepthStencilState(depthState)
        encoder.setFragmentTexture(importedTexture ?? placeholderTexture, index: 0)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        encoder.setVertexBuffer(vertices, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<UVCheckerUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<UVCheckerUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
    }

    // MARK: - Shader

    /// Procedural UV checker with simple wrap shading.
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct UVCheckerUniforms {
        float4x4 mvp;
        float4   params;  // x density, y opacity, z shading strength
    };

    struct CheckerVertexIn {
        packed_float3 position;
        packed_float3 normal;
        packed_float2 uv;
    };

    struct CheckerVertexOut {
        float4 position [[position]];
        float3 normal;
        float2 uv;
    };

    vertex CheckerVertexOut uv_checker_vertex(
        uint vid [[vertex_id]],
        const device CheckerVertexIn* vertices [[buffer(0)]],
        constant UVCheckerUniforms& u          [[buffer(1)]])
    {
        CheckerVertexOut out;
        CheckerVertexIn v = vertices[vid];
        out.position = u.mvp * float4(float3(v.position), 1.0);
        out.normal = float3(v.normal);
        out.uv = float2(v.uv);
        return out;
    }

    fragment float4 uv_checker_fragment(
        CheckerVertexOut in [[stage_in]],
        constant UVCheckerUniforms& u [[buffer(0)]],
        texture2d<float> imported     [[texture(0)]],
        sampler s                     [[sampler(0)]])
    {
        // Checker straight from UV. `floor` on each axis and a parity test: the classic form, and
        // the one that makes a stretched square visibly stretched — which is the entire point of
        // showing a checker rather than a colour.
        float2 scaled = in.uv * u.params.x;
        float2 cell = floor(scaled);
        float parity = fmod(cell.x + cell.y, 2.0);
        // Two greys rather than saturated colours: the checker has to read as a texture the model is
        // WEARING, not as a highlight competing with the distortion heatmap.
        float3 base = parity < 0.5 ? float3(0.82) : float3(0.28);

        // An imported image REPLACES the checker rather than tinting it: the two answer the same
        // question, and multiplying them would make a dark region of the artwork indistinguishable
        // from a dark checker square.
        if (u.params.w > 0.5) {
            // v flipped, because image space runs top-down while UV runs bottom-up. Sampling
            // unflipped would show every imported texture upside down against every other tool.
            base = imported.sample(s, float2(in.uv.x, 1.0 - in.uv.y)).rgb;
        }

        // Wrap shading so the form is still readable through the pattern. Double-sided, like the
        // Target pass: a back face can be the visible surface of an open shell.
        float3 n = normalize(in.normal);
        float lambert = abs(n.z) * 0.5 + 0.5;
        float shaded = mix(1.0, lambert, clamp(u.params.z, 0.0, 1.0));

        return float4(base * shaded, u.params.y);
    }
    """
}

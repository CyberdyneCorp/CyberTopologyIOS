import Metal
import simd

// EditMesh overlay pipeline (task 2.3, spec: viewport-rendering / "Animated
// EditMesh overlay pipeline" + "X-ray and occlusion control", design D2:
// dedicated overlay pipeline — the "feel" is a first-class deliverable).
//
// v1 renders the wireframe as an indexed line list over the engine's unique
// face-edge buffer (authored topology: a quad draws 4 edges, never its fan
// diagonal) plus vertex dots as point primitives. This is a plain vertex
// pipeline on purpose: it needs no GPU capability gating and is exactly what
// simulator tests exercise.
//
// Barycentric upgrade path: replace the line list with the solid EditMesh
// triangles carrying per-corner barycentric coordinates (or
// `[[barycentric_coord]]` on Apple7+), and derive the edge mask in the
// fragment shader from the barycentric distance-to-edge. That gives
// resolution-independent stroke width, interior-edge masking and per-edge
// styling (pins/tags/boundaries) in one draw — slot it in behind
// `EditMeshOverlayPath.encode` without touching the renderer.

/// User-facing overlay state (view-options popover; persisted app-side).
struct OverlaySettings: Equatable {
    /// Wireframe opacity, 0...1. 0 hides the overlay entirely.
    var opacity: Float = Float(ViewportSettings.defaultOverlayOpacity)
    /// True x-ray mode: far-side wireframe rendered depth-attenuated
    /// (spec scenario "X-ray mode").
    var xrayEnabled = false
    /// Occlusion depth threshold in NDC depth units: how far behind the
    /// Target surface edges stay visible before they are occluded.
    var occlusionBias: Float = Float(ViewportSettings.defaultOcclusionBias)
}

/// Creation micro-animation timing: a pure time→progress mapping so the
/// GPU work is one uniform per frame (no geometry churn, no frame drops).
enum OverlayAnimation {
    /// Sweep+fade duration in seconds (subtle by design).
    static let duration: Double = 0.45

    /// Progress in [0, 1] of the creation animation started at
    /// `creationTime`; 1 when no animation is running.
    static func progress(creationTime: Double?, now: Double) -> Float {
        guard let creationTime else { return 1 }
        let elapsed = (now - creationTime) / duration
        return Float(min(max(elapsed, 0), 1))
    }
}

/// Per-draw overlay uniforms. Layout must match the MSL `OverlayUniforms`
/// struct: float4x4 then three float4s.
struct OverlayUniforms: Equatable {
    var mvp: simd_float4x4
    /// Theme color (rgb) and effective opacity (a).
    var color: SIMD4<Float>
    /// x: animation progress, y: NDC occlusion depth bias,
    /// z: x-ray attenuation floor, w: vertex count (sweep normalization).
    var params: SIMD4<Float>
    /// x: point size in pixels, y: 1 on the x-ray (far-side) pass else 0,
    /// z,w: reserved.
    var misc: SIMD4<Float>
}

/// Pure uniform construction, unit-tested without a GPU.
enum OverlayUniformsFactory {
    /// Distinct overlay theme (RT-stage cyan; per-stage themes extend here).
    static let wireColor = SIMD3<Float>(0.30, 0.85, 1.0)
    /// Alpha floor multiplier for the far-side x-ray pass.
    static let xrayAttenuation: Float = 0.45
    /// Vertex dot size in pixels.
    static let pointSize: Float = 6

    /// Uniforms for the front (depth-tested, bias-forgiving) pass.
    static func main(
        mvp: simd_float4x4, settings: OverlaySettings,
        animationProgress: Float, vertexCount: Int
    ) -> OverlayUniforms {
        OverlayUniforms(
            mvp: mvp,
            color: SIMD4(wireColor, settings.opacity),
            params: SIMD4(
                animationProgress, settings.occlusionBias,
                xrayAttenuation, Float(vertexCount)
            ),
            misc: SIMD4(pointSize, 0, 0, 0)
        )
    }

    /// Uniforms for the x-ray (far-side, depth-attenuated) pass.
    static func xray(
        mvp: simd_float4x4, settings: OverlaySettings,
        animationProgress: Float, vertexCount: Int
    ) -> OverlayUniforms {
        var uniforms = main(
            mvp: mvp, settings: settings,
            animationProgress: animationProgress, vertexCount: vertexCount
        )
        uniforms.misc.y = 1
        return uniforms
    }
}

/// Dedicated overlay pipeline for EditMesh wireframes: edges as an indexed
/// line list, vertices as points, alpha-blended over the Target with two
/// depth strategies:
///
///  * occluded pass — depth compare ≤ against the Target's depth with a
///    configurable NDC bias applied in the vertex shader, so edges up to
///    the occlusion threshold behind the surface stay visible;
///  * x-ray pass (optional) — depth compare > (only fragments the Target
///    hides) with depth-attenuated alpha, making far-side topology
///    readable without flattening the model (spec scenario "X-ray mode").
///
/// Geometry lives in its own `GeometryBufferPool` (positions + edge
/// indices; same no-per-frame-allocation contract as the target pool).
@MainActor
final class EditMeshOverlayPath {
    let bufferPool: GeometryBufferPool
    private let pipelineState: MTLRenderPipelineState
    /// Depth compare ≤, writes off: overlay never disturbs Target depth.
    private let occludedDepthState: MTLDepthStencilState
    /// Depth compare >, writes off: draws only what the Target hides.
    private let xrayDepthState: MTLDepthStencilState

    private(set) var edgeIndexCount = 0
    private(set) var vertexCount = 0

    var hasGeometry: Bool { edgeIndexCount > 0 }

    /// Fails only when the embedded shader does not compile or a pipeline/
    /// depth state cannot be built (programmer error, surfaced by tests).
    init?(device: MTLDevice, commandQueue: MTLCommandQueue, preferPrivateStorage: Bool) {
        guard let library = try? device.makeLibrary(source: Self.shaderSource, options: nil)
        else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "editmesh-overlay"
        descriptor.vertexFunction = library.makeFunction(name: "overlay_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "overlay_fragment")
        descriptor.colorAttachments[0].pixelFormat = ViewportRenderer.colorPixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        descriptor.depthAttachmentPixelFormat = ViewportRenderer.depthPixelFormat

        let occluded = MTLDepthStencilDescriptor()
        occluded.depthCompareFunction = .lessEqual
        occluded.isDepthWriteEnabled = false

        let xray = MTLDepthStencilDescriptor()
        xray.depthCompareFunction = .greater
        xray.isDepthWriteEnabled = false

        guard
            let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor),
            let occludedState = device.makeDepthStencilState(descriptor: occluded),
            let xrayState = device.makeDepthStencilState(descriptor: xray)
        else { return nil }

        self.pipelineState = pipeline
        self.occludedDepthState = occludedState
        self.xrayDepthState = xrayState
        self.bufferPool = GeometryBufferPool(
            device: device, commandQueue: commandQueue,
            preferPrivateStorage: preferPrivateStorage
        )
    }

    /// Uploads EditMesh wireframe geometry (engine-compacted positions +
    /// unique face-edge indices). Returns false and clears on undrawable
    /// input or allocation failure.
    @discardableResult
    func load(
        positions: UnsafeBufferPointer<Float>, edges: UnsafeBufferPointer<UInt32>
    ) -> Bool {
        guard !positions.isEmpty, !edges.isEmpty else {
            clear()
            return false
        }
        guard
            bufferPool.upload(floats: positions, to: .position) != nil,
            bufferPool.upload(indices: edges) != nil
        else {
            clear()
            return false
        }
        vertexCount = positions.count / 3
        edgeIndexCount = edges.count
        return true
    }

    func clear() {
        edgeIndexCount = 0
        vertexCount = 0
        bufferPool.clear()
    }

    /// Encodes the overlay over an already-encoded Target. Binds pooled
    /// buffers only (never allocates at frame time).
    func encode(
        into encoder: MTLRenderCommandEncoder,
        mvp: simd_float4x4,
        settings: OverlaySettings,
        animationProgress: Float
    ) {
        guard
            hasGeometry,
            settings.opacity > 0,
            animationProgress > 0,
            let positions = bufferPool.buffer(for: .position),
            let edges = bufferPool.buffer(for: .index)
        else { return }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(positions, offset: 0, index: 0)

        var uniforms = OverlayUniformsFactory.main(
            mvp: mvp, settings: settings,
            animationProgress: animationProgress, vertexCount: vertexCount
        )
        encoder.setDepthStencilState(occludedDepthState)
        draw(edges: edges, uniforms: &uniforms, into: encoder)

        if settings.xrayEnabled {
            var xrayUniforms = OverlayUniformsFactory.xray(
                mvp: mvp, settings: settings,
                animationProgress: animationProgress, vertexCount: vertexCount
            )
            encoder.setDepthStencilState(xrayDepthState)
            draw(edges: edges, uniforms: &xrayUniforms, into: encoder)
        }
    }

    private func draw(
        edges: MTLBuffer, uniforms: inout OverlayUniforms,
        into encoder: MTLRenderCommandEncoder
    ) {
        encoder.setVertexBytes(
            &uniforms, length: MemoryLayout<OverlayUniforms>.stride, index: 1
        )
        encoder.setFragmentBytes(
            &uniforms, length: MemoryLayout<OverlayUniforms>.stride, index: 0
        )
        encoder.drawIndexedPrimitives(
            type: .line, indexCount: edgeIndexCount, indexType: .uint32,
            indexBuffer: edges, indexBufferOffset: 0
        )
        // Vertex dots reuse the same bound buffers/uniforms as points.
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: vertexCount)
    }

    // MARK: - Shader

    /// Line/point overlay shader. Compiled at runtime like the target
    /// pipeline (works identically in app bundle and unit tests).
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct OverlayUniforms {
        float4x4 mvp;
        float4   color;   // rgb theme, a = opacity
        float4   params;  // x anim progress, y NDC depth bias,
                          // z x-ray attenuation, w vertex count
        float4   misc;    // x point size, y x-ray pass flag
    };

    struct OverlayVertexOut {
        float4 position [[position]];
        float  pointSize [[point_size]];
        float  sweep;   // per-vertex sweep coordinate for the creation anim
    };

    vertex OverlayVertexOut overlay_vertex(
        uint vid [[vertex_id]],
        const device packed_float3* positions [[buffer(0)]],
        constant OverlayUniforms& u           [[buffer(1)]])
    {
        OverlayVertexOut out;
        float4 clip = u.mvp * float4(float3(positions[vid]), 1.0);
        // Occlusion threshold: pull the overlay toward the camera by a
        // configurable NDC depth bias so edges slightly behind the Target
        // surface stay visible (spec: occlusion depth threshold).
        clip.z -= u.params.y * clip.w;
        out.position = clip;
        out.pointSize = u.misc.x;
        // Sweep coordinate: vertex order fraction (engine-compacted order
        // is spatially coherent for imports). Time only moves the uniform.
        out.sweep = u.params.w > 0.0 ? float(vid) / u.params.w : 0.0;
        return out;
    }

    fragment float4 overlay_fragment(
        OverlayVertexOut in [[stage_in]],
        constant OverlayUniforms& u [[buffer(0)]])
    {
        // Creation micro-animation: index-ordered sweep with a soft fade
        // front, fully revealed at progress 1.
        float reveal = clamp((u.params.x * 1.2 - in.sweep) / 0.2, 0.0, 1.0);
        float alpha = u.color.a * reveal;
        if (u.misc.y > 0.5) {
            // X-ray pass: far-side wireframe, depth-attenuated (farther
            // fragments fade toward the attenuation floor).
            alpha *= u.params.z * (1.0 - 0.5 * in.position.z);
        }
        return float4(u.color.rgb, alpha);
    }
    """
}

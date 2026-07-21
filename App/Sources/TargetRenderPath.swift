import CyberKit
import Metal
import simd

// Target render-path strategy seam (task 2.2, design D2): the renderer talks
// to a `TargetRenderPath` and never to a concrete pipeline, so the meshlet/
// mesh-shader path can slot in behind the same interface. Today exactly one
// concrete path exists — `IndexedVertexRenderPath` — which is simultaneously
// the working path for all hardware and the mandated fallback for the
// simulator and pre-A14 devices.

/// Per-frame uniforms shared by target render paths (must match the MSL
/// `Uniforms` struct layout: float4x4 then float4).
struct ViewportUniforms {
    var mvp: simd_float4x4
    var lightDirection: SIMD4<Float>
}

/// Borrowed views of one mesh's render streams, in the engine's compacted
/// vertex order. Same lifetime contract as `Mesh.RenderBuffers`: valid only
/// inside the closure/scope that produced the pointers.
struct TargetGeometry {
    /// x,y,z per vertex.
    let positions: UnsafeBufferPointer<Float>
    /// x,y,z per vertex, unit length.
    let normals: UnsafeBufferPointer<Float>
    /// r,g,b per vertex; `nil` when the mesh carries no vertex colors
    /// (render paths substitute neutral gray).
    let colors: UnsafeBufferPointer<Float>?
    /// 3 indices per triangle into `positions`.
    let indices: UnsafeBufferPointer<UInt32>

    var isDrawable: Bool { !positions.isEmpty && !indices.isEmpty }
}

/// Which concrete pipeline renders the high-poly Target.
enum TargetRenderPathKind: String, CaseIterable, Sendable {
    /// Classic indexed vertex pipeline. Works everywhere (simulator,
    /// pre-A14 hardware) and is the mandated fallback (design D2).
    case indexedVertex
    /// Meshlet/mesh-shader pipeline with cluster LOD (design D2). Not
    /// implemented yet — follow-up to task 2.2. Selection is already
    /// capability-gated so the pipeline can slot in without renderer
    /// changes.
    case meshlet
}

/// Runtime GPU capabilities relevant to render-path selection.
struct RenderPathCapabilities: Equatable, Sendable {
    /// Metal 3 mesh shaders: Apple7 family (A14/M1) and later.
    let supportsMeshShaders: Bool
    /// Unified memory means `.storageModeShared` geometry is already
    /// GPU-optimal; without it, private storage + staging blits win.
    let hasUnifiedMemory: Bool
    /// MetalFX spatial upscaling (task 2.5). Runtime-checked via
    /// `MTLFXSpatialScaler.supportsDevice`; always false on the simulator
    /// (the framework is absent from its SDK).
    let supportsMetalFXSpatial: Bool

    init(
        supportsMeshShaders: Bool,
        hasUnifiedMemory: Bool,
        supportsMetalFXSpatial: Bool = false
    ) {
        self.supportsMeshShaders = supportsMeshShaders
        self.hasUnifiedMemory = hasUnifiedMemory
        self.supportsMetalFXSpatial = supportsMetalFXSpatial
    }

    /// Detects capabilities via `MTLDevice.supportsFamily` and the MetalFX
    /// runtime check.
    init(device: MTLDevice) {
        #if targetEnvironment(simulator)
            // The simulator advertises the host GPU's family but does not
            // implement mesh shaders; force the fallback path there.
            let meshShaders = false
        #else
            let meshShaders =
                device.supportsFamily(.metal3) && device.supportsFamily(.apple7)
        #endif
        self.init(
            supportsMeshShaders: meshShaders,
            hasUnifiedMemory: device.hasUnifiedMemory,
            supportsMetalFXSpatial: MetalFXCapability.spatialScalingSupported(device: device)
        )
    }
}

enum TargetRenderPathSelection {
    /// The path this hardware should ultimately run (spec: meshlet/LOD on
    /// mesh-shader hardware, vertex pipeline below).
    static func preferredKind(
        for capabilities: RenderPathCapabilities
    ) -> TargetRenderPathKind {
        capabilities.supportsMeshShaders ? .meshlet : .indexedVertex
    }

    /// The path the renderer instantiates today. The meshlet pipeline is a
    /// follow-up to task 2.2; until it lands, a preferred `.meshlet`
    /// resolves to `.indexedVertex` (required anyway as the simulator /
    /// pre-A14 fallback). This is an honest capability-gated seam, not a
    /// fake meshlet implementation.
    static func availableKind(
        for capabilities: RenderPathCapabilities
    ) -> TargetRenderPathKind {
        switch preferredKind(for: capabilities) {
        case .meshlet, .indexedVertex:
            return .indexedVertex
        }
    }
}

/// Strategy interface for target geometry pipelines. A path owns its
/// pipeline state and GPU geometry (via the shared `GeometryBufferPool`);
/// the renderer owns camera, depth state, pass setup, and frame pacing.
@MainActor
protocol TargetRenderPath: AnyObject {
    var kind: TargetRenderPathKind { get }
    var hasGeometry: Bool { get }
    /// Uploads the geometry into pooled GPU buffers. Returns false (and
    /// clears any previous geometry) when the input is not drawable or an
    /// allocation failed.
    @discardableResult
    func load(_ geometry: TargetGeometry) -> Bool
    /// Drops the current geometry (pool allocations are retained for reuse).
    func clear()
    /// Encodes one draw of the loaded geometry. Never allocates: binds
    /// pooled buffers only (large-mesh contract, task 2.2).
    func encode(into encoder: MTLRenderCommandEncoder, uniforms: ViewportUniforms)
}

/// Indexed-vertex target pipeline: smooth-shaded per-vertex color rendering
/// with a half-Lambert headlight (directional along the view axis) plus an
/// ambient floor. Meshes without vertex colors render in neutral gray.
@MainActor
final class IndexedVertexRenderPath: TargetRenderPath {
    /// Neutral gray used when `TargetGeometry.colors` is nil.
    static let neutralGray: Float = 0.72

    let kind: TargetRenderPathKind = .indexedVertex
    let bufferPool: GeometryBufferPool
    private let pipelineState: MTLRenderPipelineState
    private(set) var indexCount = 0

    var hasGeometry: Bool { indexCount > 0 }

    /// Fails only when the embedded shader source does not compile or the
    /// pipeline cannot be built (programmer error, surfaced by tests).
    init?(device: MTLDevice, bufferPool: GeometryBufferPool) {
        // Runtime-compiled so the pipeline works identically in the app
        // bundle, unit tests, and future previews (no default-library
        // bundle lookup).
        guard let library = try? device.makeLibrary(source: Self.shaderSource, options: nil)
        else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "target-indexed-vertex"
        descriptor.vertexFunction = library.makeFunction(name: "viewport_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "viewport_fragment")
        descriptor.colorAttachments[0].pixelFormat = ViewportRenderer.colorPixelFormat
        descriptor.depthAttachmentPixelFormat = ViewportRenderer.depthPixelFormat

        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
        else { return nil }
        self.pipelineState = pipeline
        self.bufferPool = bufferPool
    }

    @discardableResult
    func load(_ geometry: TargetGeometry) -> Bool {
        guard geometry.isDrawable else {
            clear()
            return false
        }
        var uploaded = bufferPool.upload(floats: geometry.positions, to: .position) != nil
            && bufferPool.upload(floats: geometry.normals, to: .normal) != nil
            && bufferPool.upload(indices: geometry.indices) != nil
        if let colors = geometry.colors {
            uploaded = uploaded && bufferPool.upload(floats: colors, to: .color) != nil
        } else {
            // hasColors == false: substitute a constant neutral gray stream
            // (one-time load cost; the draw itself is uniform either way).
            let gray = [Float](repeating: Self.neutralGray, count: geometry.positions.count)
            uploaded = uploaded
                && gray.withUnsafeBufferPointer { bufferPool.upload(floats: $0, to: .color) }
                != nil
        }
        guard uploaded else {
            clear()
            return false
        }
        indexCount = geometry.indices.count
        return true
    }

    func clear() {
        indexCount = 0
        bufferPool.clear()
    }

    func encode(into encoder: MTLRenderCommandEncoder, uniforms: ViewportUniforms) {
        guard
            hasGeometry,
            let positions = bufferPool.buffer(for: .position),
            let normals = bufferPool.buffer(for: .normal),
            let colors = bufferPool.buffer(for: .color),
            let indices = bufferPool.buffer(for: .index)
        else { return }

        var uniforms = uniforms
        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(positions, offset: 0, index: 0)
        encoder.setVertexBuffer(normals, offset: 0, index: 1)
        encoder.setVertexBuffer(colors, offset: 0, index: 2)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<ViewportUniforms>.stride, index: 3)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ViewportUniforms>.stride, index: 0)
        encoder.drawIndexedPrimitives(
            type: .triangle, indexCount: indexCount, indexType: .uint32,
            indexBuffer: indices, indexBufferOffset: 0
        )
    }

    // MARK: - Shader

    /// Smooth-shaded pipeline: per-vertex position/normal/color, ambient +
    /// half-Lambert headlight directional term. Compiled at runtime (see
    /// `init`).
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float4x4 mvp;
        float4   lightDirection;
    };

    struct VertexOut {
        float4 position [[position]];
        float3 normal;
        float3 color;
    };

    vertex VertexOut viewport_vertex(
        uint vid [[vertex_id]],
        const device packed_float3* positions [[buffer(0)]],
        const device packed_float3* normals   [[buffer(1)]],
        const device packed_float3* colors    [[buffer(2)]],
        constant Uniforms& uniforms           [[buffer(3)]])
    {
        VertexOut out;
        out.position = uniforms.mvp * float4(float3(positions[vid]), 1.0);
        out.normal = float3(normals[vid]);
        out.color = float3(colors[vid]);
        return out;
    }

    fragment float4 viewport_fragment(
        VertexOut in [[stage_in]],
        constant Uniforms& uniforms [[buffer(0)]])
    {
        float3 n = normalize(in.normal);
        // abs(): double-sided shading, consistent with cull mode none.
        float lambert = abs(dot(n, -uniforms.lightDirection.xyz));
        float3 shaded = in.color * (0.35 + 0.65 * lambert);
        return float4(shaded, 1.0);
    }
    """
}

import CyberKit
import Metal
import simd

/// Mesh-shader Target pipeline (openspec add-meshlet-target-path, task 3.3).
///
/// An object shader tests one meshlet per thread and dispatches a mesh threadgroup for
/// the survivors; the mesh shader emits that cluster's vertices and triangles. Two
/// mechanisms make this faster than the indexed path on a multi-million-triangle Target:
///
///  * **Vertex reuse** — a cluster's vertices are deduplicated by the engine's
///    clusterer, so each is transformed once per cluster instead of relying on the
///    hardware post-transform cache across an unbounded index stream.
///  * **Frustum culling** — a cluster wholly outside the view is rejected before any of
///    its vertices are transformed.
///
/// **Deliberately NO backface culling**, even though the engine supplies a normal cone
/// for it. The viewport renders the Target DOUBLE-SIDED — `setCullMode(.none)` plus
/// `abs(dot(n, -light))` shading — so a back-facing triangle currently contributes
/// pixels. On an open shell, a scan with holes, or the inside of a concave region seen
/// through an opening, that back face IS the visible surface, and culling it would leave
/// a hole. Backface culling is therefore a product change, not an optimisation, and is
/// out of scope here; the cone data is carried but unused so it costs nothing to enable
/// later behind a watertight check or a single-sided decision.
///
/// Because nothing is culled that the indexed path would draw, this path must be
/// **pixel-identical** to it — which is what the parity test asserts.
@MainActor
final class MeshletRenderPath: TargetRenderPath {
    /// Must match `MeshletCaps` in the engine (`core/meshlet.hpp`): the shader declares
    /// fixed-size mesh output, so a cluster larger than this would overflow it.
    static let maxVerticesPerMeshlet = 64
    static let maxTrianglesPerMeshlet = 126
    /// Threads per mesh threadgroup. One thread handles several vertices and several
    /// primitives by striding, so this need not equal either cap.
    static let meshThreadsPerGroup = 128

    let kind: TargetRenderPathKind = .meshlet
    let bufferPool: GeometryBufferPool
    private let pipelineState: MTLRenderPipelineState
    private(set) var meshletCount = 0

    var hasGeometry: Bool { meshletCount > 0 }

    /// Why the pipeline could not be built, or nil when it can.
    ///
    /// The initialiser deliberately returns nil on failure so the renderer falls back
    /// rather than blanking the viewport — but a SILENT fallback is undiagnosable, and
    /// "the meshlet path quietly isn't running" is exactly the kind of thing that
    /// otherwise gets discovered months later as a mysterious perf regression.
    static func unavailabilityReason(device: MTLDevice) -> String? {
        guard device.supportsFamily(.metal3) else { return "no Metal 3 support" }
        guard device.supportsFamily(.apple7) else { return "GPU family below Apple7 (A14/M1)" }
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: shaderSource, options: nil)
        } catch {
            return "shader compile failed: \(error)"
        }
        for name in ["meshlet_object", "meshlet_mesh", "meshlet_fragment"] {
            if library.makeFunction(name: name) == nil {
                return "missing shader function \(name)"
            }
        }
        let descriptor = MTLMeshRenderPipelineDescriptor()
        descriptor.objectFunction = library.makeFunction(name: "meshlet_object")
        descriptor.meshFunction = library.makeFunction(name: "meshlet_mesh")
        descriptor.fragmentFunction = library.makeFunction(name: "meshlet_fragment")
        descriptor.colorAttachments[0].pixelFormat = ViewportRenderer.colorPixelFormat
        descriptor.depthAttachmentPixelFormat = ViewportRenderer.depthPixelFormat
        descriptor.maxTotalThreadsPerObjectThreadgroup = 1
        descriptor.maxTotalThreadsPerMeshThreadgroup = meshThreadsPerGroup
        do {
            _ = try device.makeRenderPipelineState(descriptor: descriptor, options: [])
        } catch {
            return "pipeline creation failed: \(error)"
        }
        return nil
    }

    /// Fails when mesh shaders are unavailable or the pipeline will not build. A
    /// failure here must leave the caller free to fall back — never render nothing.
    /// `unavailabilityReason` says why.
    init?(device: MTLDevice, bufferPool: GeometryBufferPool) {
        guard device.supportsFamily(.metal3), device.supportsFamily(.apple7) else { return nil }
        guard let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
            let objectFunction = library.makeFunction(name: "meshlet_object"),
            let meshFunction = library.makeFunction(name: "meshlet_mesh"),
            let fragmentFunction = library.makeFunction(name: "meshlet_fragment")
        else { return nil }

        let descriptor = MTLMeshRenderPipelineDescriptor()
        descriptor.label = "target-meshlet"
        descriptor.objectFunction = objectFunction
        descriptor.meshFunction = meshFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = ViewportRenderer.colorPixelFormat
        descriptor.depthAttachmentPixelFormat = ViewportRenderer.depthPixelFormat
        descriptor.maxTotalThreadsPerObjectThreadgroup = 1
        descriptor.maxTotalThreadsPerMeshThreadgroup = Self.meshThreadsPerGroup

        // The mesh-pipeline overload returns (state, reflection).
        guard let pipeline = try? device.makeRenderPipelineState(
            descriptor: descriptor, options: []
        ).0 else { return nil }
        self.pipelineState = pipeline
        self.bufferPool = bufferPool
    }

    /// `TargetGeometry` carries the render streams but not the clusters, so the mesh is
    /// needed too. The renderer calls `load(_:from:)`; the protocol's `load(_:)` cannot
    /// build clusters and therefore refuses rather than silently drawing nothing.
    @discardableResult
    func load(_ geometry: TargetGeometry) -> Bool {
        clear()
        return false
    }

    /// Uploads the render streams AND the mesh's meshlet clusters.
    @discardableResult
    func load(_ geometry: TargetGeometry, from mesh: Mesh) -> Bool {
        guard geometry.isDrawable else {
            clear()
            return false
        }
        var uploaded = bufferPool.upload(floats: geometry.positions, to: .position) != nil
            && bufferPool.upload(floats: geometry.normals, to: .normal) != nil
        if let colors = geometry.colors {
            uploaded = uploaded && bufferPool.upload(floats: colors, to: .color) != nil
        } else {
            let gray = [Float](
                repeating: IndexedVertexRenderPath.neutralGray, count: geometry.positions.count
            )
            uploaded = uploaded
                && gray.withUnsafeBufferPointer { bufferPool.upload(floats: $0, to: .color) }
                != nil
        }

        var clusters = 0
        mesh.withMeshletBuffers { buffers in
            guard buffers.isDrawable else {
                uploaded = false
                return
            }
            uploaded = uploaded
                && bufferPool.upload(
                    UnsafeRawBufferPointer(buffers.meshlets), to: .meshletDescriptors
                ) != nil
                && bufferPool.upload(
                    UnsafeRawBufferPointer(buffers.vertices), to: .meshletVertices
                ) != nil
                && bufferPool.upload(
                    UnsafeRawBufferPointer(buffers.localIndices), to: .meshletIndices
                ) != nil
            clusters = buffers.meshlets.count
        }
        guard uploaded, clusters > 0 else {
            clear()
            return false
        }
        meshletCount = clusters
        return true
    }

    func clear() {
        meshletCount = 0
        bufferPool.clear()
    }

    func encode(into encoder: MTLRenderCommandEncoder, uniforms: ViewportUniforms) {
        guard
            hasGeometry,
            let positions = bufferPool.buffer(for: .position),
            let normals = bufferPool.buffer(for: .normal),
            let colors = bufferPool.buffer(for: .color),
            let descriptors = bufferPool.buffer(for: .meshletDescriptors),
            let meshletVertices = bufferPool.buffer(for: .meshletVertices),
            let meshletIndices = bufferPool.buffer(for: .meshletIndices)
        else { return }

        var uniforms = uniforms
        encoder.setRenderPipelineState(pipelineState)
        // Object stage: one thread per cluster, deciding whether to dispatch it.
        encoder.setObjectBuffer(descriptors, offset: 0, index: 0)
        encoder.setObjectBytes(&uniforms, length: MemoryLayout<ViewportUniforms>.stride, index: 1)
        // Mesh stage: the shared streams every cluster indexes into.
        encoder.setMeshBuffer(positions, offset: 0, index: 0)
        encoder.setMeshBuffer(normals, offset: 0, index: 1)
        encoder.setMeshBuffer(colors, offset: 0, index: 2)
        encoder.setMeshBuffer(descriptors, offset: 0, index: 3)
        encoder.setMeshBuffer(meshletVertices, offset: 0, index: 4)
        encoder.setMeshBuffer(meshletIndices, offset: 0, index: 5)
        encoder.setMeshBytes(&uniforms, length: MemoryLayout<ViewportUniforms>.stride, index: 6)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ViewportUniforms>.stride, index: 0)
        encoder.drawMeshThreadgroups(
            MTLSize(width: meshletCount, height: 1, depth: 1),
            threadsPerObjectThreadgroup: MTLSize(width: 1, height: 1, depth: 1),
            threadsPerMeshThreadgroup: MTLSize(
                width: Self.meshThreadsPerGroup, height: 1, depth: 1
            )
        )
    }

    // MARK: - Shader

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float4x4 mvp;
        float4   lightDirection;
    };

    // Must match CyberMeshlet (capi) field for field.
    struct Meshlet {
        uint  vertexOffset;
        uint  vertexCount;
        uint  triangleOffset;
        uint  triangleCount;
        float center[3];
        float radius;
        float coneAxis[3];
        float coneCutoff;
    };

    struct VertexOut {
        float4 position [[position]];
        float3 normal;
        float3 color;
    };

    struct Payload { uint meshletIndex; };

    using MeshletMesh = metal::mesh<VertexOut, void, 64, 126, metal::topology::triangle>;

    // Conservative frustum rejection of a bounding sphere against the clip planes
    // extracted from the MVP. Returns true when the sphere is WHOLLY outside one
    // plane — the only case it is safe to skip. Anything uncertain is kept: culling
    // a visible cluster leaves a hole, so this errs toward drawing.
    static bool sphereOutsideFrustum(float4x4 mvp, float3 center, float radius)
    {
        // Rows of the column-major MVP.
        float4 r0 = float4(mvp[0][0], mvp[1][0], mvp[2][0], mvp[3][0]);
        float4 r1 = float4(mvp[0][1], mvp[1][1], mvp[2][1], mvp[3][1]);
        float4 r2 = float4(mvp[0][2], mvp[1][2], mvp[2][2], mvp[3][2]);
        float4 r3 = float4(mvp[0][3], mvp[1][3], mvp[2][3], mvp[3][3]);

        // Metal NDC: x,y in [-1,1], z in [0,1].
        float4 planes[6] = { r3 + r0, r3 - r0, r3 + r1, r3 - r1, r2, r3 - r2 };
        for (uint i = 0; i < 6; ++i) {
            float3 n = planes[i].xyz;
            float len = length(n);
            if (len <= 0.0f) { continue; }   // degenerate plane: cannot judge, keep
            float distance = (dot(n, center) + planes[i].w) / len;
            if (distance < -radius) { return true; }
        }
        return false;
    }

    [[object]] void meshlet_object(
        object_data Payload& payload            [[payload]],
        const device Meshlet* meshlets          [[buffer(0)]],
        constant Uniforms& uniforms             [[buffer(1)]],
        uint meshletIndex                       [[threadgroup_position_in_grid]],
        mesh_grid_properties props)
    {
        const Meshlet m = meshlets[meshletIndex];
        float3 center = float3(m.center[0], m.center[1], m.center[2]);
        // NOTE: no backface test. The viewport draws the Target double-sided
        // (cull mode none + abs() shading), so a back-facing cluster can be the
        // visible surface of an open shell.
        if (sphereOutsideFrustum(uniforms.mvp, center, m.radius)) {
            props.set_threadgroups_per_grid(uint3(0, 1, 1));
            return;
        }
        payload.meshletIndex = meshletIndex;
        props.set_threadgroups_per_grid(uint3(1, 1, 1));
    }

    [[mesh]] void meshlet_mesh(
        MeshletMesh out,
        const object_data Payload& payload      [[payload]],
        const device packed_float3* positions   [[buffer(0)]],
        const device packed_float3* normals     [[buffer(1)]],
        const device packed_float3* colors      [[buffer(2)]],
        const device Meshlet* meshlets          [[buffer(3)]],
        const device uint* meshletVertices      [[buffer(4)]],
        const device uchar* meshletIndices      [[buffer(5)]],
        constant Uniforms& uniforms             [[buffer(6)]],
        uint tid                                [[thread_position_in_threadgroup]],
        uint threads                            [[threads_per_threadgroup]])
    {
        const Meshlet m = meshlets[payload.meshletIndex];
        out.set_primitive_count(m.triangleCount);

        // NOTE: `global` and `vertex` are RESERVED in MSL (an address-space
        // qualifier and a function qualifier), so naming locals either way makes
        // the declaration declare nothing and every following line fail to parse.
        for (uint v = tid; v < m.vertexCount; v += threads) {
            uint sourceIndex = meshletVertices[m.vertexOffset + v];
            VertexOut emitted;
            emitted.position = uniforms.mvp * float4(float3(positions[sourceIndex]), 1.0);
            emitted.normal = float3(normals[sourceIndex]);
            emitted.color = float3(colors[sourceIndex]);
            out.set_vertex(v, emitted);
        }
        for (uint t = tid; t < m.triangleCount; t += threads) {
            uint base = (m.triangleOffset + t) * 3;
            out.set_index(t * 3 + 0, meshletIndices[base + 0]);
            out.set_index(t * 3 + 1, meshletIndices[base + 1]);
            out.set_index(t * 3 + 2, meshletIndices[base + 2]);
        }
    }

    // Identical shading to the indexed path, so parity is exact rather than close.
    fragment float4 meshlet_fragment(
        VertexOut in [[stage_in]],
        constant Uniforms& uniforms [[buffer(0)]])
    {
        float3 n = normalize(in.normal);
        float lambert = abs(dot(n, -uniforms.lightDirection.xyz));
        float3 shaded = in.color * (0.35 + 0.65 * lambert);
        return float4(shaded, 1.0);
    }
    """
}

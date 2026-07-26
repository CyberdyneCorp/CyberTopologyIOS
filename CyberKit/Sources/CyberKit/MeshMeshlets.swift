import CyberRemesherC
import Foundation
import simd

/// Meshlet clusters for the mesh-shader Target render path
/// (openspec add-meshlet-target-path, task 3.2).
///
/// A meshlet is a small bounded cluster of triangles a Metal object/mesh shader pair
/// emits in one threadgroup. Its vertex indices address **the same compacted array
/// `withRenderBuffers` exposes**, so a renderer binds one position buffer and one
/// normal buffer and every cluster indexes into them — there is no second vertex
/// stream to keep in sync.
extension Mesh {

    /// One cluster.
    ///
    /// **Mirrors the C `CyberMeshlet` byte for byte** so the array can be handed to the
    /// GPU, and read from the engine, without a copy — a mesh can have tens of thousands
    /// of clusters, so converting them would defeat the point of a zero-copy view.
    ///
    /// The vector members are 3-Float TUPLES, not `SIMD3<Float>`, because `SIMD3<Float>`
    /// is **16 bytes, not 12** (padded to four lanes for alignment). Declaring them as
    /// `SIMD3` made this struct 56 bytes against C's 48, with every field after `center`
    /// at the wrong offset — the reinterpreted buffer read garbage. `layoutMatchesC`
    /// below is asserted by a test so that cannot regress silently.
    public struct Meshlet: Equatable, Sendable {
        public var vertexOffset: UInt32
        public var vertexCount: UInt32
        /// In TRIANGLES, not indices.
        public var triangleOffset: UInt32
        public var triangleCount: UInt32
        /// Bounding-sphere centre, as the C layout stores it.
        public var centerTuple: (Float, Float, Float)
        public var radius: Float
        /// Normal-cone axis, as the C layout stores it.
        public var coneAxisTuple: (Float, Float, Float)
        /// Minimum `dot(coneAxis, n_i)` over the cluster, so every triangle normal lies
        /// within `acos(coneCutoff)` of the axis.
        ///
        /// **Zero means NEVER backface-cull this cluster** — its normals span more than
        /// a hemisphere, so no view direction can be proven to see only back faces.
        /// Culling a visible cluster leaves a hole in the model, so the ambiguous case
        /// fails safe rather than clever.
        public var coneCutoff: Float

        /// Bounding sphere centre. Conservative: contains every cluster vertex.
        public var center: SIMD3<Float> {
            SIMD3(centerTuple.0, centerTuple.1, centerTuple.2)
        }
        /// Average triangle normal.
        public var coneAxis: SIMD3<Float> {
            SIMD3(coneAxisTuple.0, coneAxisTuple.1, coneAxisTuple.2)
        }
        /// True when the cone is usable for backface rejection at all.
        public var isBackfaceCullable: Bool { coneCutoff > 0 }

        public static func == (a: Meshlet, b: Meshlet) -> Bool {
            a.vertexOffset == b.vertexOffset && a.vertexCount == b.vertexCount
                && a.triangleOffset == b.triangleOffset && a.triangleCount == b.triangleCount
                && a.center == b.center && a.radius == b.radius
                && a.coneAxis == b.coneAxis && a.coneCutoff == b.coneCutoff
        }
    }

    /// Borrowed views of the meshlet buffers.
    ///
    /// Same lifetime contract as `RenderBuffers`: valid only inside the closure. Any
    /// mutating engine call invalidates them — and note the compacted vertex ORDER
    /// moves too, so a meshlet held across an edit is doubly stale.
    public struct MeshletBuffers {
        /// The clusters.
        public let meshlets: UnsafeBufferPointer<Meshlet>
        /// Global vertex indices, grouped per meshlet; index into the position and
        /// normal buffers from `withRenderBuffers`.
        public let vertices: UnsafeBufferPointer<UInt32>
        /// Triangle corners as LOCAL offsets into the owning meshlet's vertex slice,
        /// 3 per triangle.
        public let localIndices: UnsafeBufferPointer<UInt8>

        public var isDrawable: Bool { !meshlets.isEmpty && !localIndices.isEmpty }
        /// Total triangles across all clusters.
        public var triangleCount: Int { localIndices.count / 3 }
    }

    /// Zero-copy access to the meshlet clusters, built lazily on first request.
    ///
    /// Clustering a multi-million-triangle Target is not free, which is why the
    /// engine builds it on demand rather than with the rest of the render cache — the
    /// overlay, picking and export paths never ask for it.
    public func withMeshletBuffers<R>(_ body: (MeshletBuffers) throws -> R) rethrows -> R {
        try withExtendedLifetime(self) {
            var meshletCount = 0, vertexCount = 0, indexCount = 0
            let meshlets = cyber_mesh_meshlets_ptr(handle, &meshletCount)
            let vertices = cyber_mesh_meshlet_vertices_ptr(handle, &vertexCount)
            let localIndices = cyber_mesh_meshlet_indices_ptr(handle, &indexCount)
            // Reinterpreted, not copied: a Target can have tens of thousands of
            // clusters. Safe only because `Meshlet` mirrors `CyberMeshlet`'s layout
            // exactly — which `Mesh.meshletLayoutMatchesC` asserts, because the first
            // attempt used SIMD3<Float> (16 bytes, not 12) and silently read garbage.
            let rebound = UnsafeRawPointer(meshlets)?.bindMemory(
                to: Meshlet.self, capacity: meshletCount
            )
            let buffers = MeshletBuffers(
                meshlets: UnsafeBufferPointer(start: rebound, count: meshletCount),
                vertices: UnsafeBufferPointer(start: vertices, count: vertexCount),
                localIndices: UnsafeBufferPointer(start: localIndices, count: indexCount)
            )
            return try body(buffers)
        }
    }

    /// True when the Swift `Meshlet` really does mirror the C `CyberMeshlet` layout.
    /// Checked by a test rather than assumed: getting it wrong does not fail to
    /// compile, it silently reinterprets the buffer and yields nonsense.
    public static var meshletLayoutMatchesC: Bool {
        MemoryLayout<Meshlet>.size == MemoryLayout<CyberMeshlet>.size
            && MemoryLayout<Meshlet>.stride == MemoryLayout<CyberMeshlet>.stride
            && MemoryLayout<Meshlet>.alignment == MemoryLayout<CyberMeshlet>.alignment
    }

    /// The cluster count without materialising the buffers — for capability checks
    /// and diagnostics.
    public var meshletCount: Int {
        var count = 0
        _ = cyber_mesh_meshlets_ptr(handle, &count)
        return count
    }
}

import CyberRemesherC
import Foundation

// Render-data access for the Metal viewport (design D2: the engine owns
// geometry buffers and exposes them zero-copy; no mesh algorithms in Swift —
// triangulation, normal computation and color storage all happen engine-side
// behind the capi render cache).
extension Mesh {
    // MARK: - Copying accessors

    /// Number of triangles the mesh's faces fan-triangulate to
    /// (deterministic engine-side triangulation; an n-gon yields n-2).
    public var triangleCount: Int { cyber_mesh_triangle_count(handle) }

    /// Whether the mesh carries per-vertex colors (e.g. an OBJ with
    /// polypaint-style `v x y z r g b` lines).
    public var hasColors: Bool { cyber_mesh_has_colors(handle) != 0 }

    /// Triangulated index buffer: 3 indices per triangle into the compacted
    /// vertex order used by `positions()`. Quads and n-gons are
    /// fan-triangulated deterministically by the engine.
    public func triangleIndices() -> [UInt32] {
        let count = cyber_mesh_copy_triangle_indices(handle, nil, 0)
        guard count > 0 else { return [] }
        return [UInt32](unsafeUninitializedCapacity: count) { buffer, written in
            written = cyber_mesh_copy_triangle_indices(handle, buffer.baseAddress, count)
        }
    }

    /// Number of unique undirected face edges (a quad contributes its 4
    /// boundary edges, never the fan-triangulation diagonal — wireframe
    /// overlays draw the authored topology).
    public var edgeCount: Int { cyber_mesh_edge_count(handle) }

    /// Unique-edge index buffer: 2 indices per edge into the compacted
    /// vertex order used by `positions()`, deterministic order (faces in id
    /// order, each edge kept on first sighting).
    public func edgeIndices() -> [UInt32] {
        let count = cyber_mesh_copy_edge_indices(handle, nil, 0)
        guard count > 0 else { return [] }
        return [UInt32](unsafeUninitializedCapacity: count) { buffer, written in
            written = cyber_mesh_copy_edge_indices(handle, buffer.baseAddress, count)
        }
    }

    /// Per-vertex unit normals, laid out x,y,z per vertex in the compacted
    /// vertex order of `positions()`. Computed engine-side (imported
    /// per-corner normals averaged per vertex when present, face normals
    /// otherwise).
    public func normals() -> [Float] {
        let count = cyber_mesh_copy_normals(handle, nil, 0)
        guard count > 0 else { return [] }
        return [Float](unsafeUninitializedCapacity: count) { buffer, written in
            written = cyber_mesh_copy_normals(handle, buffer.baseAddress, count)
        }
    }

    /// Per-vertex linear RGB colors, laid out r,g,b per vertex in the
    /// compacted vertex order of `positions()`, or `nil` when the mesh
    /// carries no vertex colors.
    public func colors() -> [Float]? {
        guard hasColors else { return nil }
        let count = cyber_mesh_copy_colors(handle, nil, 0)
        guard count > 0 else { return [] }
        return [Float](unsafeUninitializedCapacity: count) { buffer, written in
            written = cyber_mesh_copy_colors(handle, buffer.baseAddress, count)
        }
    }

    // MARK: - Zero-copy views

    /// Borrowed, read-only views into the engine's internal render buffers —
    /// no copy (design D2: unified-memory sharing with the Metal renderer).
    ///
    /// Lifetime contract: the pointers belong to the engine mesh handle and
    /// are only guaranteed valid inside the `withRenderBuffers` closure that
    /// produced them (they are invalidated by any future mesh mutation and
    /// by the mesh being deallocated). Never store them, never write through
    /// them, and never send them across concurrency domains — like `Mesh`
    /// itself, `RenderBuffers` is deliberately not `Sendable`.
    public struct RenderBuffers {
        /// x,y,z per vertex, compacted vertex order.
        public let positions: UnsafeBufferPointer<Float>
        /// 3 indices per triangle into `positions`.
        public let triangleIndices: UnsafeBufferPointer<UInt32>
        /// 2 indices per unique undirected face edge into `positions`
        /// (authored wireframe topology — no fan-triangulation diagonals).
        public let edgeIndices: UnsafeBufferPointer<UInt32>
        /// x,y,z per vertex, unit length, same order as `positions`.
        public let normals: UnsafeBufferPointer<Float>
        /// r,g,b per vertex, same order as `positions`; `nil` when the mesh
        /// has no vertex colors.
        public let colors: UnsafeBufferPointer<Float>?
        /// 2 indices per tagged, live, visible edge into `positions` (loop
        /// tags, task 3.4); empty when nothing is tagged.
        public let taggedEdgeIndices: UnsafeBufferPointer<UInt32>
    }

    /// Runs `body` with zero-copy views of the engine's render buffers.
    ///
    /// The views (and anything derived from their base addresses) are valid
    /// only for the duration of `body`; see `RenderBuffers` for the full
    /// lifetime contract. An empty mesh yields empty buffers.
    public func withRenderBuffers<R>(_ body: (RenderBuffers) throws -> R) rethrows -> R {
        try withExtendedLifetime(self) {
            var positionCount = 0, indexCount = 0, edgeCount = 0, normalCount = 0
            var colorCount = 0, taggedCount = 0
            let positions = cyber_mesh_positions_ptr(handle, &positionCount)
            let indices = cyber_mesh_triangle_indices_ptr(handle, &indexCount)
            let edges = cyber_mesh_edge_indices_ptr(handle, &edgeCount)
            let normals = cyber_mesh_normals_ptr(handle, &normalCount)
            let colors = cyber_mesh_colors_ptr(handle, &colorCount)
            let tagged = cyber_mesh_tagged_edge_indices_ptr(handle, &taggedCount)
            let buffers = RenderBuffers(
                positions: UnsafeBufferPointer(start: positions, count: positionCount),
                triangleIndices: UnsafeBufferPointer(start: indices, count: indexCount),
                edgeIndices: UnsafeBufferPointer(start: edges, count: edgeCount),
                normals: UnsafeBufferPointer(start: normals, count: normalCount),
                colors: colors.map { UnsafeBufferPointer(start: $0, count: colorCount) },
                taggedEdgeIndices: UnsafeBufferPointer(start: tagged, count: taggedCount)
            )
            return try body(buffers)
        }
    }
}

// Raw engine pointers must not cross concurrency domains (the underlying
// cache belongs to a single mesh handle); Swift would otherwise infer
// `Sendable` for this trivial struct because unsafe pointers are Sendable.
@available(*, unavailable)
extension Mesh.RenderBuffers: Sendable {}

import CyberRemesherC
import Foundation
import simd

/// Typed RAII facade over the engine's `CyberSnapper` (task 3.2 prereq for
/// 3.3; spec: retopology-tools continuous Target snapping): a snapshot BVH
/// over an immutable Target mesh answering closest-surface, vertex-snap and
/// raycast queries.
///
/// Snapshot semantics: the snapper does NOT observe later changes to the
/// source mesh — recreate it if the Target ever changes. Not `Sendable` for
/// the same reason as `Mesh`: hand whole instances between tasks, never
/// share one concurrently.
public final class SurfaceSnapper {
    /// Closest point on the Target surface.
    public struct SurfaceHit: Equatable, Sendable {
        public let point: SIMD3<Float>
        /// Engine face id of the hit face (stable element id).
        public let face: UInt32
    }

    /// Nearest Target vertex within a radius.
    public struct VertexHit: Equatable, Sendable {
        public let point: SIMD3<Float>
        /// Engine vertex id (stable element id).
        public let vertex: UInt32
    }

    /// First surface hit along a ray.
    public struct RayHit: Equatable, Sendable {
        public let point: SIMD3<Float>
        /// Distance along the normalized ray direction.
        public let distance: Float
        /// Engine face id of the hit face.
        public let face: UInt32
    }

    /// Engine handle, shared with the mesh-editing ops (`MeshEditing.swift`)
    /// which pass it straight back into the capi.
    let handle: OpaquePointer

    /// Builds a snapper from `target`. Throws `.emptyMesh` when the mesh
    /// has no faces.
    public init(target: Mesh) throws {
        var out: OpaquePointer?
        try check(cyber_snapper_create(target.handle, &out))
        guard let out else { throw CyberKitError(status: CYBER_ERR_RUNTIME) }
        handle = out
    }

    deinit {
        cyber_snapper_free(handle)
    }

    /// Closest point on the Target surface to `query`.
    public func snapToSurface(_ query: SIMD3<Float>) -> SurfaceHit? {
        var point: [Float] = [0, 0, 0]
        var face: UInt32 = 0
        let hit = withQuery(query) { q in
            cyber_snapper_snap_to_surface(handle, q, &point, &face)
        }
        guard hit == 1 else { return nil }
        return SurfaceHit(point: SIMD3(point[0], point[1], point[2]), face: face)
    }

    /// Nearest Target vertex within `radius` of `query`, if any.
    public func snapToVertex(_ query: SIMD3<Float>, radius: Float) -> VertexHit? {
        var point: [Float] = [0, 0, 0]
        var vertex: UInt32 = 0
        let hit = withQuery(query) { q in
            cyber_snapper_snap_to_vertex(handle, q, radius, &point, &vertex)
        }
        guard hit == 1 else { return nil }
        return VertexHit(point: SIMD3(point[0], point[1], point[2]), vertex: vertex)
    }

    /// First surface hit along `origin + t * direction`, `t` in
    /// `(0, maxDistance]`. The direction need not be normalized.
    public func raycast(
        origin: SIMD3<Float>, direction: SIMD3<Float>, maxDistance: Float = .greatestFiniteMagnitude
    ) -> RayHit? {
        var point: [Float] = [0, 0, 0]
        var distance: Float = 0
        var face: UInt32 = 0
        let o: [Float] = [origin.x, origin.y, origin.z]
        let d: [Float] = [direction.x, direction.y, direction.z]
        guard cyber_snapper_raycast(handle, o, d, maxDistance, &point, &distance, &face) == 1
        else { return nil }
        return RayHit(
            point: SIMD3(point[0], point[1], point[2]), distance: distance, face: face
        )
    }

    private func withQuery<R>(
        _ query: SIMD3<Float>, _ body: (UnsafePointer<Float>) -> R
    ) -> R {
        let q: [Float] = [query.x, query.y, query.z]
        return q.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}

// MARK: - EditMesh element queries (world space)

extension Mesh {
    /// A nearest-element pick against this mesh (brute force at EditMesh
    /// scale, engine-side; deterministic — ties break toward lower ids).
    public struct VertexPick: Equatable, Sendable {
        public let vertex: UInt32
        public let position: SIMD3<Float>
    }

    public struct EdgePick: Equatable, Sendable {
        public let edge: UInt32
        /// Closest point on the edge segment.
        public let point: SIMD3<Float>
    }

    /// Nearest live vertex within `maxDistance` of `query`, if any.
    public func nearestVertex(
        to query: SIMD3<Float>, maxDistance: Float
    ) -> VertexPick? {
        var vertex: UInt32 = 0
        var position: [Float] = [0, 0, 0]
        let q: [Float] = [query.x, query.y, query.z]
        guard cyber_mesh_nearest_vertex(handle, q, maxDistance, &vertex, &position) == 1
        else { return nil }
        return VertexPick(
            vertex: vertex, position: SIMD3(position[0], position[1], position[2])
        )
    }

    /// Nearest live vertex within `maxDistance` of `query` SKIPPING
    /// `excluded` — the merge-snap detection query for a vertex being
    /// dragged (task 3.7, spec: pencil-interaction / "Snap feedback"): the
    /// dragged vertex sits exactly at the query point, so the unfiltered
    /// query could only ever return it. Returns nil when no OTHER vertex
    /// is in range.
    public func nearestVertex(
        to query: SIMD3<Float>, maxDistance: Float, excluding excluded: UInt32
    ) -> VertexPick? {
        var vertex: UInt32 = 0
        var position: [Float] = [0, 0, 0]
        let q: [Float] = [query.x, query.y, query.z]
        guard
            cyber_mesh_nearest_vertex_excluding(
                handle, q, maxDistance, excluded, &vertex, &position
            ) == 1
        else { return nil }
        return VertexPick(
            vertex: vertex, position: SIMD3(position[0], position[1], position[2])
        )
    }

    /// Nearest live edge within `maxDistance` of `query`, if any.
    public func nearestEdge(to query: SIMD3<Float>, maxDistance: Float) -> EdgePick? {
        var edge: UInt32 = 0
        var point: [Float] = [0, 0, 0]
        let q: [Float] = [query.x, query.y, query.z]
        guard cyber_mesh_nearest_edge(handle, q, maxDistance, &edge, &point) == 1
        else { return nil }
        return EdgePick(edge: edge, point: SIMD3(point[0], point[1], point[2]))
    }

    /// Endpoint vertex ids of a live edge, or `nil` for a dead/out-of-range
    /// edge id.
    public func edgeEndpoints(of edge: UInt32) -> (UInt32, UInt32)? {
        var out: [UInt32] = [0, 0]
        guard cyber_mesh_edge_endpoints(handle, edge, &out) == 1 else { return nil }
        return (out[0], out[1])
    }

    /// Whether a live edge borders exactly one face; `nil` for a dead id.
    public func isBoundaryEdge(_ edge: UInt32) -> Bool? {
        switch cyber_mesh_is_boundary_edge(handle, edge) {
        case 1: return true
        case 0: return false
        default: return nil
        }
    }

    /// Position of a live vertex, or `nil` for a dead/out-of-range id.
    public func vertexPosition(_ vertex: UInt32) -> SIMD3<Float>? {
        var out: [Float] = [0, 0, 0]
        guard cyber_mesh_vertex_position(handle, vertex, &out) == 1 else { return nil }
        return SIMD3(out[0], out[1], out[2])
    }
}

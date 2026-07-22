import CyberRemesherC
import Foundation
import simd

// Build-tool operations (task 4.1; spec: retopology-tools / "Core RT action
// roster" — Build Quad, Build Triangle, Merge Pair, Path Distribute,
// Surface Cut).
//
// Thin typed facades over the engine patch-0016/0017 capi entry points;
// every algorithm (mixed-ring face building with neighbor-consistent
// winding, boundary-edge growth, Dijkstra shortest path, arc-length
// redistribution, segment-restricted knife cut with n-gon triangulation)
// runs engine-side (design D1). Merge Pair itself composes from the
// existing `mergeVertices`/`dissolveEdges` ops. The mutating calls follow
// the MeshEditing contract: render cache invalidated, argument failures
// throw `.invalidArgument` leaving the mesh unchanged.
extension Mesh {
    /// One ring slot of `buildFace`: reuse an existing live vertex (welding
    /// the new face onto existing topology) or create a new one.
    public enum BuildRingSlot: Equatable, Sendable {
        case existing(UInt32)
        case point(SIMD3<Float>)
    }

    /// Result of `buildFace`: the new face, the final ring (existing +
    /// created ids in the order the engine committed, which may be the
    /// reversed input when winding was corrected against a neighbor), and
    /// just the created ids.
    public struct BuiltFace: Equatable, Sendable {
        public let face: UInt32
        public let ringVertices: [UInt32]
        public let newVertices: [UInt32]
    }

    /// Builds ONE face over a mixed ring of existing vertices and new
    /// points (Build Quad / Build Triangle): 3 or 4 slots, new points
    /// snapped onto the Target first when a snapper is given, winding
    /// corrected to stay consistent with a reused boundary edge's face.
    /// Throws `.invalidArgument` (mesh unchanged) on dead ids, repeated
    /// ring vertices, or degenerate rings.
    @discardableResult
    public func buildFace(
        ring: [BuildRingSlot], snapping snapper: SurfaceSnapper? = nil
    ) throws -> BuiltFace {
        var ids: [UInt32] = []
        var xyz: [Float] = []
        ids.reserveCapacity(ring.count)
        xyz.reserveCapacity(ring.count * 3)
        for slot in ring {
            switch slot {
            case .existing(let vertex):
                ids.append(vertex)
                xyz.append(contentsOf: [0, 0, 0])
            case .point(let point):
                ids.append(CYBER_BUILD_NEW_VERTEX)
                xyz.append(contentsOf: [point.x, point.y, point.z])
            }
        }
        var face: UInt32 = 0
        var ringOut = [UInt32](repeating: 0, count: ring.count)
        try ids.withUnsafeBufferPointer { idBuffer in
            try xyz.withUnsafeBufferPointer { pointBuffer in
                try check(cyber_retopo_build_face(
                    handle, ring.count, idBuffer.baseAddress, pointBuffer.baseAddress,
                    snapper?.handle, &face, &ringOut
                ))
            }
        }
        let existing = Set(ids.filter { $0 != CYBER_BUILD_NEW_VERTEX })
        return BuiltFace(
            face: face,
            ringVertices: ringOut,
            newVertices: ringOut.filter { !existing.contains($0) }
        )
    }

    /// Grows the single triangle on a BOUNDARY edge into a quad (Build
    /// Quad's triangle-edge drag): splits the edge and drops the new ring
    /// vertex at `point` (snapped when a snapper is given). Returns the new
    /// vertex id. Throws `.invalidArgument` (mesh unchanged) when the edge
    /// is dead, interior, or its face is not a triangle.
    @discardableResult
    public func growBoundaryEdge(
        _ edge: UInt32, to point: SIMD3<Float>, snapping snapper: SurfaceSnapper? = nil
    ) throws -> UInt32 {
        let xyz: [Float] = [point.x, point.y, point.z]
        var vertex: UInt32 = 0
        try check(cyber_retopo_grow_boundary_edge(
            handle, edge, xyz, snapper?.handle, &vertex
        ))
        return vertex
    }

    /// Live faces adjacent to a live edge with their ring sizes (vertex
    /// counts) — the Build tools dispatch on quad-edge vs triangle-edge.
    /// Empty for a dead edge id.
    public func edgeFaces(of edge: UInt32) -> [(face: UInt32, sides: Int)] {
        var faces: [UInt32] = [0, 0]
        var sizes: [Int] = [0, 0]
        let count = Int(cyber_mesh_edge_faces(handle, edge, &faces, &sizes))
        guard count > 0 else { return [] }
        return (0..<min(count, 2)).map { (faces[$0], sizes[$0]) }
    }

    /// Shortest edge path between two live vertices (engine Dijkstra,
    /// Euclidean weights), endpoints inclusive in from → to order. Empty
    /// when either vertex is dead, they are equal, or no path exists.
    public func shortestVertexPath(from: UInt32, to: UInt32) -> [UInt32] {
        let count = cyber_mesh_shortest_vertex_path(handle, from, to, nil, 0)
        guard count > 0 else { return [] }
        var out = [UInt32](repeating: 0, count: count)
        _ = cyber_mesh_shortest_vertex_path(handle, from, to, &out, count)
        return out
    }

    /// Path Distribute: repositions the ordered vertex chain so its
    /// vertices sit evenly (by arc length) along the chain's own polyline;
    /// endpoints stay fixed, moved vertices snap onto the Target when a
    /// snapper is given. Positions only — topology untouched. Throws
    /// `.invalidArgument` (mesh unchanged) on short, dead, repeated, or
    /// edge-disconnected chains.
    public func distributePath(
        _ vertices: [UInt32], snapping snapper: SurfaceSnapper? = nil
    ) throws {
        try vertices.withUnsafeBufferPointer { buffer in
            try check(cyber_retopo_distribute_path(
                handle, buffer.baseAddress, vertices.count, snapper?.handle
            ))
        }
    }

    /// Surface Cut: knife cut along the straight segment `from → to` as
    /// seen along `viewDirection`. Edges crossing the cut plane within the
    /// segment's extent split (new vertices snapped when a snapper is
    /// given), faces carrying two non-adjacent cut vertices split between
    /// them, and resulting n-gons auto-triangulate when
    /// `triangulatingNGons`. Returns the split counts (0/0 = nothing under
    /// the knife). Throws `.invalidArgument` (mesh unchanged) on a
    /// degenerate segment or view direction.
    @discardableResult
    public func surfaceCut(
        from: SIMD3<Float>, to: SIMD3<Float>, viewDirection: SIMD3<Float>,
        triangulatingNGons: Bool = true, snapping snapper: SurfaceSnapper? = nil
    ) throws -> (splitEdges: Int, splitFaces: Int) {
        let a: [Float] = [from.x, from.y, from.z]
        let b: [Float] = [to.x, to.y, to.z]
        let view: [Float] = [viewDirection.x, viewDirection.y, viewDirection.z]
        var splitEdges = 0
        var splitFaces = 0
        try check(cyber_retopo_surface_cut(
            handle, a, b, view, triangulatingNGons ? 1 : 0, snapper?.handle,
            &splitEdges, &splitFaces
        ))
        return (splitEdges, splitFaces)
    }
}

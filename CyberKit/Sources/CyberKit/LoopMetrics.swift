import CyberRemesherC
import Foundation

/// Measurements of one edge loop, backing the Loop Info inspector (task
/// 4.3; spec: retopology-tools / "Loop Info inspection (vertex/edge counts,
/// boundary length, snapping state in O(loop) time)").
///
/// Produced entirely engine-side (`cyber_mesh_loop_metrics`, engine patch
/// 0020): one loop walk plus one pass over its edges, no global scan — the
/// spec's O(loop) budget holds however large the mesh is.
public struct LoopMetrics: Equatable, Sendable {
    /// Edges in the loop.
    public var edgeCount: Int
    /// Distinct vertices the loop touches (== `edgeCount` when closed,
    /// one more when open).
    public var vertexCount: Int
    /// True when the loop wraps around (and therefore has no endpoints).
    public var isClosed: Bool
    /// Summed edge length along the loop (the spec's "boundary length").
    public var length: Float
    /// Terminal vertices of an OPEN chain, in walk order; nil when closed.
    public var endpoints: (UInt32, UInt32)?
    /// Loop edges that are mesh boundary edges (one incident face).
    public var boundaryEdgeCount: Int
    /// Snapping state against the Target — nil when the document has no
    /// Target to measure against.
    public var snapping: Snapping?

    /// How well the loop sits on the Target surface.
    public struct Snapping: Equatable, Sendable {
        /// Loop vertices within tolerance of the Target surface.
        public var snappedVertexCount: Int
        /// Largest distance from a loop vertex to the Target surface.
        public var maxDistance: Float

        public init(snappedVertexCount: Int, maxDistance: Float) {
            self.snappedVertexCount = snappedVertexCount
            self.maxDistance = maxDistance
        }
    }

    public init(
        edgeCount: Int, vertexCount: Int, isClosed: Bool, length: Float,
        endpoints: (UInt32, UInt32)?, boundaryEdgeCount: Int, snapping: Snapping?
    ) {
        self.edgeCount = edgeCount
        self.vertexCount = vertexCount
        self.isClosed = isClosed
        self.length = length
        self.endpoints = endpoints
        self.boundaryEdgeCount = boundaryEdgeCount
        self.snapping = snapping
    }

    /// True when every measured vertex is on the Target. Nil-safe: an
    /// unmeasured loop (no Target) is not "fully snapped".
    public var isFullySnapped: Bool {
        guard let snapping else { return false }
        return snapping.snappedVertexCount == vertexCount
    }

    public static func == (lhs: LoopMetrics, rhs: LoopMetrics) -> Bool {
        lhs.edgeCount == rhs.edgeCount && lhs.vertexCount == rhs.vertexCount
            && lhs.isClosed == rhs.isClosed && lhs.length == rhs.length
            && lhs.endpoints?.0 == rhs.endpoints?.0 && lhs.endpoints?.1 == rhs.endpoints?.1
            && lhs.boundaryEdgeCount == rhs.boundaryEdgeCount && lhs.snapping == rhs.snapping
    }
}

extension Mesh {
    /// Measures the edge loop through `edge` in O(loop) (design D1: the
    /// walk and the measurement both run engine-side). Read-only — the
    /// render cache and pointer views survive.
    ///
    /// Returns nil when `edge` is dead or yields no loop, so the inspector
    /// simply shows nothing rather than a zeroed chip. Passing the
    /// document's `snapper` fills in the snapping state; without one the
    /// `snapping` field stays nil.
    public func loopMetrics(from edge: UInt32, snapping snapper: SurfaceSnapper? = nil)
        -> LoopMetrics?
    {
        var raw = CyberLoopMetrics()
        guard cyber_mesh_loop_metrics(handle, edge, snapper?.handle, &raw) == CYBER_OK,
            raw.edge_count > 0
        else { return nil }
        return LoopMetrics(
            edgeCount: Int(raw.edge_count),
            vertexCount: Int(raw.vertex_count),
            isClosed: raw.closed == 1,
            length: raw.length,
            endpoints: raw.has_endpoints == 1 ? (raw.endpoint_a, raw.endpoint_b) : nil,
            boundaryEdgeCount: Int(raw.boundary_edge_count),
            snapping: raw.snap_measured == 1
                ? LoopMetrics.Snapping(
                    snappedVertexCount: Int(raw.snapped_vertex_count),
                    maxDistance: raw.max_snap_distance)
                : nil
        )
    }
}

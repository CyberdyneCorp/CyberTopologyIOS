import Foundation

// Finding the quad patch a face belongs to (openspec add-patch-selection-scope).
//
// A patch is the GRID BLOCK the face sits in: flood fill across shared edges,
// stopping at separatrices — the edge loops traced from every irregular
// (non-valence-4) vertex — and at the mesh boundary and at non-quad faces.
//
// That is the retopology notion of a quad patch, and the reason the obvious
// alternatives were rejected: a connected ISLAND is the entire cage after an
// auto-retopo, so a tap would select everything; a CREASE ANGLE has nothing to
// stop at on an organic model, so a tap on the bunny's ear bleeds into the head.
//
// Pure over the public Mesh API — no engine handle beyond the queries any mesh
// answers — so every rule below is unit-testable.

public enum QuadPatch {
    /// An undirected edge, as the pair of vertices that bound it. Face ids are
    /// not durable across a topology change and edge ids are not exposed by
    /// every path, but a vertex pair names the same edge from either side.
    struct Edge: Hashable {
        let low: UInt32
        let high: UInt32

        init(_ a: UInt32, _ b: UInt32) {
            low = min(a, b)
            high = max(a, b)
        }
    }

    /// The mesh's adjacency, built once per query.
    struct Topology {
        /// Faces on each edge: one for a boundary edge, two for an interior one.
        var edgeFaces: [Edge: [UInt32]] = [:]
        /// The ring of each live face, in order.
        var rings: [UInt32: [UInt32]] = [:]
        /// Neighbouring vertices of each vertex — its valence is this count.
        var neighbors: [UInt32: Set<UInt32>] = [:]
        /// Vertices touched by a face that is not a quad. Such a vertex has no
        /// grid to be regular in, so a walk through it is meaningless.
        var nonQuadVertices: Set<UInt32> = []

        init(_ mesh: Mesh) {
            for face in mesh.liveFaceIDs() {
                let ring = mesh.faceVertices(face)
                guard ring.count >= 3 else { continue }
                rings[face] = ring
                if ring.count != 4 { nonQuadVertices.formUnion(ring) }
                for (index, vertex) in ring.enumerated() {
                    let next = ring[(index + 1) % ring.count]
                    edgeFaces[Edge(vertex, next), default: []].append(face)
                    neighbors[vertex, default: []].insert(next)
                    neighbors[next, default: []].insert(vertex)
                }
            }
        }

        func isQuad(_ face: UInt32) -> Bool { rings[face]?.count == 4 }

        func isBoundary(_ edge: Edge) -> Bool { (edgeFaces[edge]?.count ?? 0) < 2 }

        /// A vertex where the grid changes — where a separatrix starts.
        ///
        /// The valence that counts as REGULAR depends on where the vertex sits:
        /// 4 in the interior, but 3 on a boundary, where a rim vertex of a quad
        /// grid has two edges along the rim and one heading in. Treating every
        /// boundary vertex as irregular instead rakes a separatrix inward from
        /// every rim vertex of an open cage, which walls off every interior edge
        /// and leaves each face its own patch — a double-tap on a flat grid would
        /// select exactly one quad. A rim CORNER (valence 2) is genuinely
        /// irregular, and its walks run along the rim, which the fill already
        /// stops at.
        func isIrregular(_ vertex: UInt32) -> Bool {
            if nonQuadVertices.contains(vertex) { return true }
            guard let ring = neighbors[vertex] else { return true }
            let onBoundary = ring.contains { isBoundary(Edge(vertex, $0)) }
            return ring.count != (onBoundary ? 3 : 4)
        }
    }

    /// The faces of the patch containing `seed`.
    ///
    /// Returns just the seed when it is not a quad: a triangle or n-gon has no
    /// grid to belong to, and pretending otherwise would flood the fill through
    /// the very place the topology stops being regular.
    public static func faces(containing seed: UInt32, in mesh: Mesh) -> Set<UInt32> {
        let topology = Topology(mesh)
        guard topology.rings[seed] != nil else { return [] }
        guard topology.isQuad(seed) else { return [seed] }

        let walls = separatrixEdges(in: topology)
        var patch: Set<UInt32> = [seed]
        var frontier = [seed]
        while let face = frontier.popLast() {
            guard let ring = topology.rings[face] else { continue }
            for (index, vertex) in ring.enumerated() {
                let edge = Edge(vertex, ring[(index + 1) % ring.count])
                // A separatrix, a boundary, and a non-quad neighbour are all
                // walls: the patch ends where the regular grid does.
                guard !walls.contains(edge), let sides = topology.edgeFaces[edge] else { continue }
                for neighbor in sides
                where neighbor != face && topology.isQuad(neighbor) && !patch.contains(neighbor) {
                    patch.insert(neighbor)
                    frontier.append(neighbor)
                }
            }
        }
        return patch
    }

    /// Every edge lying on a separatrix: the straight walks leaving each
    /// irregular vertex. These are the walls the fill will not cross.
    ///
    /// Traced once for the whole mesh rather than per seed, because a walk from
    /// a distant singularity can be the very wall that bounds this patch.
    static func separatrixEdges(in topology: Topology) -> Set<Edge> {
        var walls: Set<Edge> = []
        for (vertex, ring) in topology.neighbors where topology.isIrregular(vertex) {
            for neighbor in ring {
                walk(from: vertex, towards: neighbor, in: topology, marking: &walls)
            }
        }
        return walls
    }

    /// Walks STRAIGHT from `origin` through `next` and marks the edges crossed.
    ///
    /// "Straight" at a valence-4 vertex means the edge belonging to NEITHER face
    /// of the edge just walked in on — the opposite edge of the cross, which is
    /// what makes the walk follow one grid direction. The walk stops at the next
    /// irregular vertex, which is where the patch it bounds ends.
    private static func walk(
        from origin: UInt32, towards next: UInt32, in topology: Topology,
        marking walls: inout Set<Edge>
    ) {
        var previous = origin
        var current = next
        // Bounded by the edge count: a walk cannot cross more edges than exist,
        // and a closed loop through only regular vertices would otherwise spin.
        var remaining = topology.edgeFaces.count + 1
        while remaining > 0 {
            remaining -= 1
            let edge = Edge(previous, current)
            // Already walled by another walk: the rest of this line is too, since
            // separatrices that meet run on together.
            if !walls.insert(edge).inserted { return }
            if topology.isIrregular(current) { return }
            guard let ahead = opposite(of: edge, at: current, in: topology) else { return }
            previous = current
            current = ahead
        }
    }

    /// The vertex straight ahead: across the unique edge at `vertex` that
    /// belongs to neither face of `edge`.
    private static func opposite(
        of edge: Edge, at vertex: UInt32, in topology: Topology
    ) -> UInt32? {
        guard let sides = topology.edgeFaces[edge], let ring = topology.neighbors[vertex] else {
            return nil
        }
        let touching = Set(sides)
        var candidates: [UInt32] = []
        for neighbor in ring {
            let outgoing = Edge(vertex, neighbor)
            guard outgoing != edge else { continue }
            let faces = Set(topology.edgeFaces[outgoing] ?? [])
            if faces.isDisjoint(with: touching) { candidates.append(neighbor) }
        }
        // Exactly one edge is opposite in a regular quad fan. Anything else means
        // the walk has reached geometry it cannot read as a grid, and stopping is
        // the honest answer.
        return candidates.count == 1 ? candidates[0] : nil
    }
}

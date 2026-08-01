import Foundation
import simd

// Halving quad density (openspec add-halve-density; spec: retopology-tools /
// "Halving the cage's quad density"): the counterpart to Subdivide. Every other
// edge loop in each loop family is dissolved, so each 2x2 block of quads becomes
// one quad and a 16x16 cage becomes 8x8.
//
// Composed from existing engine ops — `edgeLoop`, `dissolveEdges`,
// `mergeVertices` — but NOT in the obvious way. Two things the obvious
// implementation gets wrong, both recorded in the change:
//
//   * Dissolving a loop's edges does not leave quads. Two quads sharing a
//     dissolved edge merge into a SIX-sided face, whose two extra corners are
//     the dissolved edge's endpoints, now valence-2 and sitting mid-side. They
//     have to be removed for the result to be a quad.
//   * The two families must be processed ONE AT A TIME. Dissolving both first
//     strands each block's centre vertex inside the merged face with no edges at
//     all, which nothing composed from `mergeVertices` can reach.
//
// Silhouette-preserving by construction: the kept loops include the boundary
// loops, and every removal is a merge INTO a surviving vertex, whose position is
// what survives. Nothing is averaged and nothing is reprojected.
extension Mesh {
    /// What one halving did.
    public struct HalvedDensity: Equatable, Sendable {
        public let facesBefore: Int
        public let facesAfter: Int
        /// Loops dissolved, summed over both families.
        public let dissolvedLoops: Int
        /// How many of the two grid directions were actually halved.
        ///
        /// A direction with an ODD number of quads across cannot be: its last
        /// "every other" loop is the far boundary, so dissolving it would move the
        /// silhouette. Halving the direction that CAN be halved is still worth
        /// doing — reported from device on a 5 x 6 patch, where refusing both left
        /// the artist with nothing — but the artist has to be told it was one.
        public var directionsHalved: Int = 2
    }

    public enum HalveDensityFailure: Error, Equatable {
        /// No faces to halve.
        case noCage
        /// A triangle or n-gon: no loop structure to halve.
        case notQuadOnly
        /// An interior vertex of valence other than four — a pole. A loop
        /// through it cannot be walked end to end, so the alternation would
        /// dead-end partway across the cage.
        case notGridRegular
        /// No open boundary to start the loop ordering from. A closed cage is
        /// out of scope for this command (and would almost always hit
        /// `notGridRegular` anyway, since closing a cage needs poles).
        case noBoundary
        /// Fewer than two quads across a family: nothing to halve.
        case tooFewCells
        /// A family spans an ODD number of quads, so "every other loop" has no
        /// consistent answer. Halving anyway would leave one row or column at
        /// double width — worse than declining, because an untouched cage is
        /// obvious and a silently mangled one has to be hunted for.
        case oddCellCount
        /// A mid-side vertex left by the dissolve had no surviving neighbour to
        /// fold into. That means the loop bookkeeping is wrong, and continuing
        /// would leave an n-gon in a cage the caller believes is quad-only.
        case strandedMidVertex(UInt32)
        /// The cage is quad-only and pole-free, but its faces do not form ONE
        /// rectangular block — more than one patch, or an L-shaped outline. Kept
        /// separate from `notGridRegular` because the artist's next move differs:
        /// a pole has to be re-topologized away, while a second patch merely has
        /// to be halved on its own.
        case notRectangular
    }

    /// Halves the cage's quad density.
    ///
    /// Validates BOTH families before mutating anything, so a refusal can never
    /// leave a half-halved cage.
    @discardableResult
    public func halveDensity() throws -> HalvedDensity {
        let facesBefore = faceCount
        guard facesBefore > 0 else { throw HalveDensityFailure.noCage }
        guard try stats().quads == facesBefore else { throw HalveDensityFailure.notQuadOnly }

        var adjacency = try QuadAdjacency(of: self)
        try adjacency.requireGridRegular()

        // Seed the two families at a CORNER of the patch, where one boundary edge
        // of each family meets. Seeding from "the lowest-id boundary edge" instead
        // is id-dependent and wrong: land mid-side and there is no perpendicular
        // boundary edge there at all, so the second seed falls back to a PARALLEL
        // one and both passes halve the same family. A freshly imported grid hides
        // this — its lowest id happens to sit at a corner — and an already-halved
        // one does not.
        let (seedA, seedB) = try adjacency.cornerSeeds(in: self)
        let ringA = adjacency.perpendicularRing(from: seedA)
        let ringB = adjacency.perpendicularRing(from: seedB)
        // Each direction is judged ON ITS OWN. Requiring BOTH to be even refused a
        // 5 x 6 patch outright — reported from device — when the 6 direction halves
        // perfectly well and only the 5 cannot. Refuse only when NEITHER can.
        try Self.requireEnoughCells(ringA)
        try Self.requireEnoughCells(ringB)
        // The cage has to be a RECTANGLE for "every other loop" to have an answer,
        // and a rectangle is exactly a cage whose two spans multiply to its face
        // count. An L-shape passes `requireGridRegular` — its extra faces meet at
        // BOUNDARY vertices, which are regular at valence 3 — and used to be caught
        // only by accident, because one of its spans happened to be odd. Judging
        // each direction on its own merits removed that accident, so the real
        // invariant is stated here instead.
        guard (ringA.count - 1) * (ringB.count - 1) == facesBefore else {
            throw HalveDensityFailure.notRectangular
        }
        let canHalveA = Self.hasEvenCells(ringA)
        let canHalveB = Self.hasEvenCells(ringB)
        guard canHalveA || canHalveB else { throw HalveDensityFailure.oddCellCount }

        // Family B's ids will not survive family A's pass, so remember it by
        // DIRECTION and re-find it afterwards.
        let directionB = try adjacency.direction(of: seedB, in: self)

        var dissolved = canHalveA ? try halveFamily(ring: ringA) : 0
        if canHalveB {
            // Rebuilt whether or not A ran, so there is ONE path through here.
            adjacency = try QuadAdjacency(of: self)
            let reseeded = try adjacency.boundaryEdge(mostParallelTo: directionB, in: self)
            dissolved += try halveFamily(ring: adjacency.perpendicularRing(from: reseeded))
        }
        return HalvedDensity(
            facesBefore: facesBefore, facesAfter: faceCount, dissolvedLoops: dissolved,
            directionsHalved: (canHalveA ? 1 : 0) + (canHalveB ? 1 : 0)
        )
    }

    /// Dissolves every other loop of one family and reduces the merged n-gons
    /// back to quads. Returns how many loops it dissolved.
    private func halveFamily(ring: [UInt32]) throws -> Int {
        // Keep index 0 (a boundary loop, so the silhouette survives) and every
        // even loop after it; dissolve the odd ones.
        var edges: [UInt32] = []
        var midVertices: Set<UInt32> = []
        var loops = 0
        for index in stride(from: 1, to: ring.count, by: 2) {
            let loop = edgeLoop(from: ring[index])
            guard !loop.isEmpty else { throw HalveDensityFailure.notGridRegular }
            loops += 1
            edges.append(contentsOf: loop)
            for edge in loop {
                guard let ends = edgeEndpoints(of: edge) else { continue }
                midVertices.insert(ends.0)
                midVertices.insert(ends.1)
            }
        }
        guard loops > 0 else { return 0 }
        _ = try dissolveEdges(edges)

        // Every vertex of a dissolved loop is now valence-2 and mid-side: its
        // remaining two edges are the PERPENDICULAR ones, which run to vertices
        // that survive. Merging it into one of those removes it and collapses the
        // side back to a single edge — and because the survivor is the `keep`,
        // its position is what remains, so the cage does not move.
        //
        // Which vertices they are is KNOWN rather than detected. A geometric
        // "is this collinear?" test would also catch a patch's own corner
        // vertices, which are legitimately valence-2, and destroy the silhouette.
        for vertex in midVertices.sorted() {
            // Already gone: it was some earlier merge's partner.
            guard vertexPosition(vertex) != nil else { continue }
            let neighbours = QuadAdjacency.liveNeighbours(of: vertex, in: self)
            guard let keep = neighbours.first(where: { !midVertices.contains($0) }) else {
                // Loud, not silent. A mid-side vertex with no surviving neighbour to
                // fold into means the loop bookkeeping is wrong for this cage, and
                // skipping it leaves an n-gon for someone to find later.
                throw HalveDensityFailure.strandedMidVertex(vertex)
            }
            try mergeVertices(keep: keep, remove: vertex)
        }
        return loops
    }

    /// A family spans `ring.count - 1` quads (the ring is one loop per cell
    /// boundary, from one side of the patch to the other).
    /// A direction has to have something to halve at all.
    private static func requireEnoughCells(_ ring: [UInt32]) throws {
        guard ring.count - 1 >= 2 else { throw HalveDensityFailure.tooFewCells }
    }

    /// Whether "every other loop" has an answer in this direction: with an ODD
    /// number of cells the last odd loop IS the far boundary, so dissolving it
    /// would move the silhouette.
    private static func hasEvenCells(_ ring: [UInt32]) -> Bool {
        (ring.count - 1) % 2 == 0
    }
}

/// One O(edges) snapshot of the adjacency the halving walks: edge endpoints,
/// each edge's faces, and each vertex's edges. Built once per pass — the ring
/// walk and the regularity check would otherwise each rescan the sparse id
/// space.
struct QuadAdjacency {
    private(set) var endpoints: [UInt32: (UInt32, UInt32)] = [:]
    private(set) var facesOfEdge: [UInt32: [UInt32]] = [:]
    private(set) var edgesOfVertex: [UInt32: [UInt32]] = [:]
    private(set) var faceRings: [UInt32: [UInt32]] = [:]

    init(of mesh: Mesh) throws {
        let live = mesh.edgeCount
        guard live > 0 else { throw Mesh.HalveDensityFailure.noCage }
        var seen = 0
        var id: UInt32 = 0
        // Sparse ids: the scan runs to the id CAPACITY, never to a
        // multiple of the live count (see `Mesh.edgeCapacity`).
        let limit = mesh.edgeCapacity
        while seen < live, Int(id) < limit {
            defer { id += 1 }
            guard let ends = mesh.edgeEndpoints(of: id) else { continue }
            seen += 1
            endpoints[id] = ends
            facesOfEdge[id] = mesh.edgeFaces(of: id).map(\.face)
            edgesOfVertex[ends.0, default: []].append(id)
            edgesOfVertex[ends.1, default: []].append(id)
        }
        for face in mesh.liveFaceIDs() {
            faceRings[face] = mesh.faceVertices(face)
        }
    }

    /// Every INTERIOR vertex must have valence 4, or a loop through it cannot be
    /// walked end to end.
    func requireGridRegular() throws {
        for (_, edges) in edgesOfVertex {
            let interior = edges.allSatisfy { (facesOfEdge[$0]?.count ?? 0) == 2 }
            guard !interior || edges.count == 4 else {
                throw Mesh.HalveDensityFailure.notGridRegular
            }
        }
    }

    func isBoundary(_ edge: UInt32) -> Bool { (facesOfEdge[edge]?.count ?? 0) == 1 }

    /// How aligned a patch corner's two boundary edges may be and still count as
    /// a corner. A real corner is near 0; two edges continuing along one side are
    /// near 1.
    static let cornerMaxAlignment: Float = 0.7

    /// The two loop-family seeds: the boundary edges meeting at the SHARPEST
    /// corner of the patch, one per family. Vertices are visited in id order so
    /// the choice — and therefore the whole halving — is reproducible.
    func cornerSeeds(in mesh: Mesh) throws -> (UInt32, UInt32) {
        var best: (a: UInt32, b: UInt32, alignment: Float)?
        for vertex in edgesOfVertex.keys.sorted() {
            let boundary = (edgesOfVertex[vertex] ?? []).filter { isBoundary($0) }.sorted()
            guard boundary.count == 2,
                let first = try? direction(of: boundary[0], in: mesh),
                let second = try? direction(of: boundary[1], in: mesh)
            else { continue }
            let alignment = abs(simd_dot(first, second))
            if alignment < (best?.alignment ?? .greatestFiniteMagnitude) {
                best = (boundary[0], boundary[1], alignment)
            }
        }
        guard let best, best.alignment <= QuadAdjacency.cornerMaxAlignment else {
            throw Mesh.HalveDensityFailure.noBoundary
        }
        return (best.a, best.b)
    }

    /// The boundary edge whose direction is most PARALLEL to `direction` — how a
    /// family is found again after the other family's pass renumbered every id.
    func boundaryEdge(mostParallelTo direction: SIMD3<Float>, in mesh: Mesh) throws -> UInt32 {
        var best: (edge: UInt32, alignment: Float)?
        // Sorted: a dictionary's order is not reproducible, and ties here would
        // otherwise make the whole halving non-deterministic.
        for edge in facesOfEdge.keys.sorted() where facesOfEdge[edge]?.count == 1 {
            guard let other = try? self.direction(of: edge, in: mesh) else { continue }
            let alignment = abs(simd_dot(direction, other))
            if alignment > (best?.alignment ?? -1) {
                best = (edge, alignment)
            }
        }
        guard let best else { throw Mesh.HalveDensityFailure.noBoundary }
        return best.edge
    }

    func direction(of edge: UInt32, in mesh: Mesh) throws -> SIMD3<Float> {
        guard let ends = endpoints[edge],
            let a = mesh.vertexPosition(ends.0), let b = mesh.vertexPosition(ends.1),
            simd_length(b - a) > 1e-9
        else { throw Mesh.HalveDensityFailure.notGridRegular }
        return simd_normalize(b - a)
    }

    /// Live neighbours of `vertex`, lowest id first (a deterministic merge
    /// partner). Read from the MESH, not from this snapshot: the cleanup runs
    /// after a dissolve, so the snapshot is stale by then.
    static func liveNeighbours(of vertex: UInt32, in mesh: Mesh) -> [UInt32] {
        let live = mesh.edgeCount
        guard live > 0 else { return [] }
        var out: Set<UInt32> = []
        var seen = 0
        var id: UInt32 = 0
        // Sparse ids: the scan runs to the id CAPACITY, never to a
        // multiple of the live count (see `Mesh.edgeCapacity`).
        let limit = mesh.edgeCapacity
        while seen < live, Int(id) < limit {
            defer { id += 1 }
            guard let ends = mesh.edgeEndpoints(of: id) else { continue }
            seen += 1
            if ends.0 == vertex {
                out.insert(ends.1)
            } else if ends.1 == vertex {
                out.insert(ends.0)
            }
        }
        return out.sorted()
    }

    /// One representative edge per loop of `seed`'s family, in order across the
    /// cage: step to the edge topologically OPPOSITE within the next quad, which
    /// belongs to the next parallel loop. Starting from a boundary edge, one
    /// forward walk covers the family, ending on the far boundary.
    func perpendicularRing(from seed: UInt32) -> [UInt32] {
        var ring = [seed]
        var visited: Set<UInt32> = [seed]
        var current = seed
        var previousFace: UInt32?
        while true {
            guard let faces = facesOfEdge[current] else { break }
            guard let face = faces.first(where: { $0 != previousFace }) else { break }
            guard let next = oppositeEdge(in: face, to: current), !visited.contains(next) else {
                break
            }
            ring.append(next)
            visited.insert(next)
            previousFace = face
            current = next
        }
        return ring
    }

    /// The edge of a QUAD `face` opposite to `edge`: the ring's other two
    /// vertices, in ring order.
    private func oppositeEdge(in face: UInt32, to edge: UInt32) -> UInt32? {
        guard let ends = endpoints[edge] else { return nil }
        let ring = faceRings[face] ?? []
        guard ring.count == 4 else { return nil }
        for index in 0..<4 {
            let a = ring[index], b = ring[(index + 1) % 4]
            guard (a == ends.0 && b == ends.1) || (a == ends.1 && b == ends.0) else { continue }
            let c = ring[(index + 2) % 4], d = ring[(index + 3) % 4]
            return (edgesOfVertex[c] ?? []).first { candidate in
                guard let other = endpoints[candidate] else { return false }
                return (other.0 == c && other.1 == d) || (other.0 == d && other.1 == c)
            }
        }
        return nil
    }
}

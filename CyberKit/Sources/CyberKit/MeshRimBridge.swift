import Foundation
import simd

// Rim bridge (openspec add-stroke-rim-bridge; spec: pencil-interaction / "A
// stroke across a gap bridges the two facing rims with quads").
//
// A stroke drawn across an unfilled gap — from a vertex on one open rim, over
// bare Target, to a vertex on the rim facing it — asks for the corridor between
// those two rims to be filled with quads. The recognizer names only the
// CORRESPONDING PAIR of vertices; the walk that turns that pair into a quad
// strip lives here.
//
// Composed from existing engine ops (`boundaryChain` + `buildFace`) rather than
// a new C++ entry point, like the grid-continuation fill and `WeaveFillDomain`:
// the algorithm is a boundary walk over engine queries, and every mutation it
// makes is a single engine `buildFace`.
extension Mesh {
    /// What one bridge created.
    public struct RimBridge: Equatable, Sendable {
        /// New quads, in build order (column-major: all rows of a column
        /// before the next column).
        public let faces: [UInt32]
        /// Vertices created for the INTERIOR rows, in creation order. Empty for
        /// a single-row bridge, which reuses rim vertices only.
        public let newVertices: [UInt32]
        /// Paired steps bridged — the number of quad columns along the rims.
        public let columns: Int
        /// Quad rows across the gap.
        public let rows: Int
    }

    public enum RimBridgeFailure: Error, Equatable {
        /// The vertex carries no boundary edge, so there is no rim to bridge
        /// from — bridging interior topology would stack faces on existing ones.
        case notOnOpenRim(UInt32)
        /// The two vertices are the same, or already share an edge: no gap.
        case noGap
        /// The straight span between the two vertices runs through other
        /// vertices, so they are two points along ONE rim stretch rather than
        /// two sides of a gap. Bridging them would throw a single quad over the
        /// topology between them.
        case noCorridor
        /// No pair of rim directions runs the same way in space, or the rims
        /// diverge immediately — the two rims do not face each other.
        case rimsDoNotFace
        /// A position query failed or a step collapsed to zero length.
        case degenerate
    }

    /// How far apart a pair may drift, as a multiple of the FIRST pair's gap,
    /// before the rims count as no longer facing each other. A corridor that
    /// opens out past this is a different gap, not the one the stroke crossed.
    static let rimDivergenceFactor: Float = 2.5

    /// How much of a rail step may point ALONG the gap (|cos| against the current
    /// rung) before the rim counts as folding back up the corridor rather than
    /// running beside it. Measured against both ends: the device case that
    /// stitched quads over open Target sat at 0.997, while a corridor whose rim
    /// tapers at 45 degrees sits at 0.707.
    static let maximumStepAlongGap: Float = 0.85

    /// Bridges the two open rims that `a` and `b` sit on, reading that pair as
    /// ONE correspondence: both rims are walked outward from it and each paired
    /// step emits a quad, so the fill extends past the two anchors for as far as
    /// the rims keep facing each other.
    ///
    /// Rim vertices are REUSED and never moved. Across the gap the strip is
    /// subdivided into as many rows as the gap is wide in mean rim cells (capped
    /// by `maximumRows`), and those interior vertices are snapped onto the Target
    /// when a snapper is given — without that, one bridge quad would span several
    /// cells and come out stretched.
    ///
    /// Every quad is built on a rim edge (one incident face) or on an edge this
    /// bridge just created, so a bridge can never stack a face on an existing
    /// one: the invariant is topological here, not a geometric containment test.
    ///
    /// Throws before mutating anything when the pair cannot be bridged. An engine
    /// rejection PART WAY through the strip leaves the earlier quads in place —
    /// the journaled apply path discards the whole transaction in that case, so
    /// no partially bridged mesh reaches the document.
    @discardableResult
    public func bridgeRims(
        from a: UInt32, to b: UInt32, maximumColumns: Int = 24, maximumRows: Int = 8,
        snapping snapper: SurfaceSnapper? = nil
    ) throws -> RimBridge {
        guard a != b, !shareEdge(a, b) else { throw RimBridgeFailure.noGap }
        guard let anchorA = vertexPosition(a), let anchorB = vertexPosition(b) else {
            throw RimBridgeFailure.degenerate
        }
        let (railA, railB) = try rails(
            from: a, to: b, anchorA: anchorA, anchorB: anchorB, maximumColumns: maximumColumns
        )

        // Positions are captured BEFORE any build so the interpolated interior
        // rows are all measured against the same, pre-bridge rim geometry.
        let positionsA = try railA.map { try position(of: $0) }
        let positionsB = try railB.map { try position(of: $0) }

        // Where the corridor CLOSES, the cage has already subdivided the wall that
        // closes it, and those rim vertices are the bridge's interior rows —
        // exactly, at their real positions. Reading them off the rim rather than
        // interpolating is what survives curvature: on a domed cage the straight
        // chord between a wall's two ends bows away from the wall's own vertices,
        // so a radius-based weld misses them and leaves the wall T-junctioned
        // against the bridge (the device case: six new vertices where two were
        // needed). A wall that the cage subdivided also DEFINES the row count —
        // the same "continue the neighbour's loops" rule the grid fill uses.
        let arcs = railA.indices.map {
            closingArc(from: railA[$0], to: railB[$0], maximumRows: maximumRows)
        }
        let rows = arcs.first(where: { !$0.isEmpty }).map { $0.count + 1 }
            ?? rowCount(positionsA: positionsA, positionsB: positionsB, maximumRows: maximumRows)

        // grid[column][row]: row 0 is rail A, row `rows` is rail B, the closing
        // wall's own vertices fill their column, and anything still missing is
        // created on demand and shared by its four quads.
        var grid: [[UInt32?]] = railA.indices.map { column in
            var slots = [UInt32?](repeating: nil, count: rows + 1)
            slots[0] = railA[column]
            slots[rows] = railB[column]
            return slots
        }
        for (column, arc) in arcs.enumerated() where arc.count == rows - 1 {
            for (offset, vertex) in arc.enumerated() {
                grid[column][offset + 1] = vertex
            }
        }
        var faces: [UInt32] = []
        var created: [UInt32] = []
        var claimed = Set(railA + railB)
        let cell = meanCell(positionsA: positionsA, positionsB: positionsB)
        build: for column in 0..<(railA.count - 1) {
            for row in 0..<rows {
                let corners = [
                    (column, row), (column + 1, row), (column + 1, row + 1), (column, row + 1),
                ]
                var slots: [BuildRingSlot] = []
                for corner in corners {
                    if let existing = grid[corner.0][corner.1] {
                        slots.append(.existing(existing))
                        continue
                    }
                    let point = simd_mix(
                        positionsA[corner.0], positionsB[corner.0],
                        SIMD3(repeating: Float(corner.1) / Float(rows))
                    )
                    // A row point that lands ON an existing vertex REUSES it. A
                    // corridor closed by a SUBDIVIDED wall has a rim vertex
                    // exactly where a row lands; creating a second vertex there
                    // would leave the wall T-junctioned against the bridge — a
                    // crack no solver, unwrap or bake can read. Bounded by the
                    // row spacing as well as the cell, so a weld can never reach
                    // across a row and collapse the grid.
                    let radius = min(
                        Self.rungClearanceCells * cell,
                        0.45 * simd_distance(positionsA[corner.0], positionsB[corner.0])
                            / Float(rows)
                    )
                    if let pick = nearestVertex(to: point, maxDistance: radius),
                        !claimed.contains(pick.vertex) {
                        grid[corner.0][corner.1] = pick.vertex
                        claimed.insert(pick.vertex)
                        slots.append(.existing(pick.vertex))
                    } else {
                        slots.append(.point(point))
                    }
                }
                let built: BuiltFace
                do {
                    built = try buildFace(ring: slots, snapping: snapper)
                } catch {
                    // A ring the engine refuses (it already bounds a live face, or
                    // it is degenerate) ENDS the walk instead of failing the whole
                    // bridge: the columns already built are legitimate quads the
                    // artist asked for. With nothing built there is no bridge, so
                    // the refusal is the caller's answer.
                    if faces.isEmpty { throw error }
                    break build
                }
                let committed = Self.committedRing(built.ringVertices, slots: slots)
                for (index, corner) in corners.enumerated() where grid[corner.0][corner.1] == nil {
                    grid[corner.0][corner.1] = committed[index]
                    claimed.insert(committed[index])
                    created.append(committed[index])
                }
                faces.append(built.face)
            }
        }
        return RimBridge(
            faces: faces, newVertices: created, columns: railA.count - 1, rows: rows
        )
    }

    // MARK: - The walk

    /// The two paired rails, in walk order. The pair is a CORRESPONDENCE, not an
    /// extent: the rails fan out from it BOTH ways, so the corridor fills on
    /// either side of where the stroke happened to land. Bounded by
    /// `maximumColumns` in total and by the per-step stop conditions.
    private func rails(
        from a: UInt32, to b: UInt32, anchorA: SIMD3<Float>, anchorB: SIMD3<Float>,
        maximumColumns: Int
    ) throws -> (railA: [UInt32], railB: [UInt32]) {
        let directionsA = try rimDirections(from: a)
        let directionsB = try rimDirections(from: b)

        // Each rim can be walked two ways, so four combinations. A combination is
        // admissible only when its two first steps run the SAME way in space; the
        // most parallel admissible one wins. The rejected antiparallel
        // combinations are exactly the ones that would emit bow-tie quads, so
        // choosing the direction replaces a per-quad fold check.
        var chosen: (score: Float, a: Int, b: Int)?
        for (indexA, candidateA) in directionsA.enumerated() {
            for (indexB, candidateB) in directionsB.enumerated() {
                guard let firstA = candidateA.first, let firstB = candidateB.first,
                    let stepA = unitStep(from: anchorA, to: firstA),
                    let stepB = unitStep(from: anchorB, to: firstB)
                else { continue }
                let score = simd_dot(stepA, stepB)
                if score > 0, score > (chosen?.score ?? 0) {
                    chosen = (score, indexA, indexB)
                }
            }
        }
        guard let chosen else { throw RimBridgeFailure.rimsDoNotFace }

        let firstGap = simd_distance(anchorA, anchorB)
        guard firstGap > 1e-9 else { throw RimBridgeFailure.degenerate }
        // Clearance is measured in RIM CELLS, not as a fraction of the span: a
        // wide gap crossed by a finely subdivided rim has neighbouring rim
        // vertices about one cell to either side, and a span-relative tolerance
        // would grow past them and refuse the very multi-row bridges this op
        // exists for.
        let clearance = Self.rungClearanceCells
            * cellEstimate(anchorA: anchorA, anchorB: anchorB,
                           directionsA: directionsA, directionsB: directionsB)
        // The ANCHORS must face each other across a GAP — and only the anchors are
        // held to this. Two points a few edges apart along the SAME rim satisfy
        // every other condition here, and bridging them would throw one quad over
        // the topology between them, so the anchor span must be clear of other
        // vertices. Later pairs are deliberately exempt (see `walk`).
        guard rungIsClear(from: anchorA, to: anchorB, endpoints: [a, b], clearance: clearance)
        else { throw RimBridgeFailure.noCorridor }

        var used: Set<UInt32> = [a, b]
        let forward = walk(
            fromA: a, fromB: b, alongA: directionsA[chosen.a], alongB: directionsB[chosen.b],
            firstGap: firstGap, limit: maximumColumns, used: &used
        )
        // The complementary combination is the same corridor walked the other
        // way. `used` carries over, so a walk that meets the first one around a
        // closed rim stops instead of doubling back over its own quads.
        let backward = walk(
            fromA: a, fromB: b, alongA: directionsA[1 - chosen.a],
            alongB: directionsB[1 - chosen.b], firstGap: firstGap,
            limit: maximumColumns - forward.a.count, used: &used
        )
        let railA = backward.a.reversed() + [a] + forward.a
        let railB = backward.b.reversed() + [b] + forward.b
        guard railA.count >= 2 else { throw RimBridgeFailure.rimsDoNotFace }
        return (Array(railA), Array(railB))
    }

    /// Pairs off successive rim vertices from an anchored pair, stopping at the
    /// FIRST condition that says the rims have stopped facing each other.
    private func walk(
        fromA a: UInt32, fromB b: UInt32, alongA pathA: [UInt32], alongB pathB: [UInt32],
        firstGap: Float, limit: Int, used: inout Set<UInt32>
    ) -> (a: [UInt32], b: [UInt32]) {
        var railA: [UInt32] = []
        var railB: [UInt32] = []
        var step = 0
        while railA.count < limit, step < pathA.count, step < pathB.count {
            let nextA = pathA[step]
            let nextB = pathB[step]
            // A rim that walked onto a vertex the other rail owns has met it
            // around a closed loop: no corridor is left to bridge.
            guard nextA != nextB, !used.contains(nextA), !used.contains(nextB),
                let previousA = vertexPosition(railA.last ?? a),
                let previousB = vertexPosition(railB.last ?? b),
                let pointA = vertexPosition(nextA), let pointB = vertexPosition(nextB),
                let stepA = unitStep(from: previousA, to: nextA),
                let stepB = unitStep(from: previousB, to: nextB),
                let gap = unitGap(from: previousB, to: previousA),
                simd_dot(stepA, stepB) > 0,
                // Neither rail may step ALONG the gap. A rim that folds back up the
                // corridor has stopped bounding it — past that turn the two rims
                // are just two edges of open surface, and pairing them stitches
                // skewed quads over bare Target (the device case: the upper rim
                // turned up the gap at 0.997 while the lower one still ran across
                // it, so the parallel and divergence tests both passed).
                abs(simd_dot(stepA, gap)) < Self.maximumStepAlongGap,
                abs(simd_dot(stepB, gap)) < Self.maximumStepAlongGap,
                simd_distance(pointA, pointB) <= firstGap * Self.rimDivergenceFactor
            else { break }
            // NO clearance test past the anchors. The span between a later pair
            // may legitimately run along existing topology: a corridor closed by
            // a SUBDIVIDED wall puts a rim vertex right on it, and refusing that
            // step is what made a real notch bridge produce nothing at all. Such
            // a vertex is welded into the row grid instead (see `bridgeRims`),
            // and a column the engine refuses ends the walk there.
            railA.append(nextA)
            railB.append(nextB)
            used.insert(nextA)
            used.insert(nextB)
            step += 1
        }
        return (railA, railB)
    }

    /// The rim successors of `vertex` — EXACTLY two arrays, one per walk
    /// direction, each excluding the anchor and either possibly empty (an anchor
    /// at the end of an open rim). Index stability is what lets a caller ask for
    /// "the other way" as `1 - index`.
    private func rimDirections(from vertex: UInt32) throws -> [[UInt32]] {
        for edge in boundaryEdges(incidentTo: vertex) {
            guard let chain = boundaryChain(through: edge),
                let anchor = chain.vertices.firstIndex(of: vertex)
            else { continue }
            let ring = chain.vertices
            guard ring.count >= 2 else { continue }
            if chain.closed {
                return [
                    (1..<ring.count).map { ring[(anchor + $0) % ring.count] },
                    (1..<ring.count).map { ring[(anchor - $0 + ring.count) % ring.count] },
                ]
            }
            return [Array(ring[(anchor + 1)...]), Array(ring[..<anchor].reversed())]
        }
        throw RimBridgeFailure.notOnOpenRim(vertex)
    }

    /// Rows so the bridge quads come out roughly cage-sized: the mean gap
    /// measured in mean rim cells. A gap narrower than a cell stays one row.
    private func rowCount(
        positionsA: [SIMD3<Float>], positionsB: [SIMD3<Float>], maximumRows: Int
    ) -> Int {
        let cell = meanCell(positionsA: positionsA, positionsB: positionsB)
        guard cell > 1e-9 else { return 1 }
        let gaps = zip(positionsA, positionsB).map { simd_distance($0, $1) }
        let meanGap = gaps.reduce(0, +) / Float(gaps.count)
        return max(1, min(maximumRows, Int((meanGap / cell).rounded())))
    }

    /// How much longer than the straight span a rim path may be and still count as
    /// the WALL that closes a corridor. A genuine wall runs roughly straight across
    /// the gap; the long way round the cage's boundary does not, and mistaking it
    /// for a wall would read the whole cage as the bridge's row count.
    static let closingArcSlack: Float = 1.5

    /// The rim vertices between `u` and `v` when the corridor CLOSES there — the
    /// interior of the boundary arc joining them, in u → v order, empty when they
    /// are not joined by a short rim path.
    ///
    /// "Short" is the whole point: on a connected cage ANY two rim vertices are
    /// joined by some boundary arc, so the qualifier is that the arc runs roughly
    /// straight across the gap (`closingArcSlack`) rather than detouring around the
    /// cage, and that it is no deeper than the row cap.
    private func closingArc(from u: UInt32, to v: UInt32, maximumRows: Int) -> [UInt32] {
        guard let start = vertexPosition(u), let end = vertexPosition(v) else { return [] }
        let span = simd_distance(start, end)
        guard span > 1e-9 else { return [] }
        for edge in boundaryEdges(incidentTo: u) {
            guard let chain = boundaryChain(through: edge) else { continue }
            let ring = chain.vertices
            guard let from = ring.firstIndex(of: u), let to = ring.firstIndex(of: v) else {
                continue
            }
            let candidates: [[UInt32]] = [
                walkArc(ring, from: from, to: to, closed: chain.closed),
                Array(walkArc(ring, from: to, to: from, closed: chain.closed).reversed()),
            ]
            for path in candidates {
                let interior = path.dropFirst().dropLast()
                guard !interior.isEmpty, interior.count + 1 <= maximumRows,
                    pathLength(path) <= span * Self.closingArcSlack
                else { continue }
                return Array(interior)
            }
        }
        return []
    }

    /// The inclusive slice of `ring` from `from` to `to`, wrapping only on a closed
    /// chain. Empty when an open chain would need to wrap.
    private func walkArc(
        _ ring: [UInt32], from: Int, to: Int, closed: Bool
    ) -> [UInt32] {
        if !closed {
            guard from <= to else { return [] }
            return Array(ring[from...to])
        }
        var out: [UInt32] = []
        var index = from
        while true {
            out.append(ring[index])
            if index == to { break }
            index = (index + 1) % ring.count
            if out.count > ring.count { return [] }
        }
        return out
    }

    private func pathLength(_ vertices: [UInt32]) -> Float {
        var total: Float = 0
        for index in 1..<max(vertices.count, 1) {
            guard let a = vertexPosition(vertices[index - 1]),
                let b = vertexPosition(vertices[index])
            else { return .greatestFiniteMagnitude }
            total += simd_distance(a, b)
        }
        return total
    }

    /// Mean rim-edge length along the two rails — the cage's local cell size,
    /// which sets both the row count and how near a row point has to land to weld
    /// onto an existing vertex.
    private func meanCell(positionsA: [SIMD3<Float>], positionsB: [SIMD3<Float>]) -> Float {
        var total: Float = 0
        var count = 0
        for rail in [positionsA, positionsB] {
            for index in 1..<rail.count {
                total += simd_distance(rail[index - 1], rail[index])
                count += 1
            }
        }
        return count > 0 ? total / Float(count) : 0
    }

    // MARK: - Pieces

    /// Maps ring SLOTS to the ids the engine committed for them.
    ///
    /// `buildFace` may hand back the reversed ring when it corrects the new
    /// face's winding against a reused boundary edge, so a bridge that assumed
    /// the input order would record its shared interior vertices under the wrong
    /// grid slots and tear the strip. The mapping is recovered from the
    /// `.existing` anchors instead — every ring the walk builds has at least two
    /// — and tolerates a rotation as well as a reversal.
    static func committedRing(_ committed: [UInt32], slots: [BuildRingSlot]) -> [UInt32] {
        let count = slots.count
        guard committed.count == count else { return committed }
        let anchors: [(slot: Int, id: UInt32)] = slots.enumerated().compactMap { index, slot in
            if case .existing(let id) = slot { return (index, id) }
            return nil
        }
        guard let first = anchors.first,
            let start = committed.firstIndex(of: first.id)
        else { return committed }
        var forward = true
        if let second = anchors.dropFirst().first,
            let found = committed.firstIndex(of: second.id) {
            forward = found == wrap(start + second.slot - first.slot, count)
        }
        return (0..<count).map { slot in
            let offset = slot - first.slot
            return committed[wrap(forward ? start + offset : start - offset, count)]
        }
    }

    private static func wrap(_ index: Int, _ count: Int) -> Int {
        ((index % count) + count) % count
    }

    /// Live edges incident to `vertex`, with the other endpoint. Edge ids are
    /// sparse, so this probes past the live count the way
    /// `WeaveFillDomain.openBoundaryEdges` does rather than assuming density.
    private func incidentEdges(to vertex: UInt32) -> [(edge: UInt32, other: UInt32)] {
        let live = edgeCount
        guard live > 0 else { return [] }
        var found: [(edge: UInt32, other: UInt32)] = []
        var seen = 0
        var id: UInt32 = 0
        // Sparse ids: the scan runs to the id CAPACITY, never to a
        // multiple of the live count (see `Mesh.edgeCapacity`).
        let limit = edgeCapacity
        while seen < live, Int(id) < limit {
            if let ends = edgeEndpoints(of: id) {
                seen += 1
                if ends.0 == vertex {
                    found.append((id, ends.1))
                } else if ends.1 == vertex {
                    found.append((id, ends.0))
                }
            }
            id += 1
        }
        return found
    }

    /// Boundary edges incident to `vertex` — the rims it can be bridged from.
    private func boundaryEdges(incidentTo vertex: UInt32) -> [UInt32] {
        incidentEdges(to: vertex)
            .filter { isBoundaryEdge($0.edge) == true }
            .map(\.edge)
    }

    /// Any edge at all between them, boundary or interior: two vertices already
    /// joined have no gap to bridge.
    private func shareEdge(_ a: UInt32, _ b: UInt32) -> Bool {
        incidentEdges(to: a).contains { $0.other == b }
    }

    /// How close to a rung, in RIM CELLS, another vertex may come before the
    /// "gap" counts as occupied topology. Well under half a cell: a rung across a
    /// real gap has its nearest rim neighbours about a full cell to either side,
    /// while a span along a rim runs straight THROUGH them.
    private static let rungClearanceCells: Float = 0.35

    /// The local rim cell size — the mean first step away from either anchor
    /// along either rim. Falls back to a quarter of the gap when no step is
    /// measurable, which keeps the clearance test conservative rather than off.
    private func cellEstimate(
        anchorA: SIMD3<Float>, anchorB: SIMD3<Float>,
        directionsA: [[UInt32]], directionsB: [[UInt32]]
    ) -> Float {
        var total: Float = 0
        var count = 0
        for (anchor, directions) in [(anchorA, directionsA), (anchorB, directionsB)] {
            for path in directions {
                guard let next = path.first, let point = vertexPosition(next) else { continue }
                total += simd_distance(anchor, point)
                count += 1
            }
        }
        guard count > 0, total > 1e-9 else { return simd_distance(anchorA, anchorB) * 0.25 }
        return total / Float(count)
    }

    /// Is the span between one paired step clear of OTHER live vertices?
    ///
    /// This is what separates a gap from a rim: a rung drawn across an unfilled
    /// corridor passes through nothing, while a span between two points of the
    /// same rim stretch runs straight through the vertices between them. Checked
    /// against pre-bridge geometry only — the interior row vertices a bridge
    /// creates sit on their own rungs by design.
    private func rungIsClear(
        from start: SIMD3<Float>, to end: SIMD3<Float>, endpoints: [UInt32], clearance: Float
    ) -> Bool {
        let span = end - start
        let length = simd_length(span)
        guard length > 1e-9 else { return false }
        let direction = span / length
        let excluded = Set(endpoints)
        for vertex in liveVertexIDs() where !excluded.contains(vertex) {
            guard let point = vertexPosition(vertex) else { continue }
            let along = simd_dot(point - start, direction)
            // Only the OPEN span matters; a vertex off either end is beside the
            // rung, not in it.
            guard along > clearance, along < length - clearance else { continue }
            if simd_distance(point, start + direction * along) < clearance {
                return false
            }
        }
        return true
    }

    private func position(of vertex: UInt32) throws -> SIMD3<Float> {
        guard let position = vertexPosition(vertex) else {
            throw RimBridgeFailure.degenerate
        }
        return position
    }

    /// Unit direction of one rung — the gap the pair spans. nil when it collapsed.
    private func unitGap(from start: SIMD3<Float>, to end: SIMD3<Float>) -> SIMD3<Float>? {
        let span = end - start
        let length = simd_length(span)
        guard length > 1e-9 else { return nil }
        return span / length
    }

    /// Unit direction from `origin` to `vertex`; nil when either is unusable or
    /// the step has collapsed.
    private func unitStep(from origin: SIMD3<Float>, to vertex: UInt32) -> SIMD3<Float>? {
        guard let point = vertexPosition(vertex) else { return nil }
        let step = point - origin
        let length = simd_length(step)
        guard length > 1e-9 else { return nil }
        return step / length
    }
}

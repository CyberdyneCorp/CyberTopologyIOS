import CyberKit
import Foundation
import Testing
import simd

/// Halving quad density (openspec add-halve-density; spec: retopology-tools /
/// "Halving the cage's quad density"): every other edge loop in each family is
/// dissolved, so each 2x2 block of quads becomes one quad — the counterpart to
/// Subdivide.
///
/// Public-API + generated grid fixtures, so this suite runs on DEVICE too
/// (mirrored into the app-hosted target in project.yml).
@Suite("Halve density ops")
struct HalveDensityOpsTests {
    private func mesh(fromOBJ text: String) throws -> Mesh {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("halve-\(UUID().uuidString).obj")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Mesh.loadOBJ(at: url)
    }

    /// A `cells` x `cells` quad grid on the z = 0 plane, unit cells.
    private func grid(cells: Int) throws -> Mesh {
        var lines: [String] = []
        let side = cells + 1
        for y in 0..<side {
            for x in 0..<side { lines.append("v \(x) \(y) 0") }
        }
        for y in 0..<cells {
            for x in 0..<cells {
                let a = y * side + x + 1  // 1-based OBJ
                lines.append("f \(a) \(a + 1) \(a + side + 1) \(a + side)")
            }
        }
        return try mesh(fromOBJ: lines.joined(separator: "\n"))
    }

    private func positions(of mesh: Mesh) -> [SIMD3<Float>] {
        mesh.liveVertexIDs().compactMap { mesh.vertexPosition($0) }
    }

    // MARK: - The halving

    @Test("a 4x4 grid halves to 2x2, quad-only")
    func gridHalves() throws {
        let m = try grid(cells: 4)
        #expect(m.faceCount == 16)
        #expect(m.vertexCount == 25)

        let report = try m.halveDensity()
        #expect(report.facesBefore == 16)
        #expect(report.facesAfter == 4, "4x4 should halve to 2x2, got \(m.faceCount)")
        #expect(m.faceCount == 4)
        // 3x3 vertices survive: the even loops' intersections.
        #expect(m.vertexCount == 9)
        // Still quad-only — the dissolve alone would leave six-sided faces.
        #expect(try m.stats().quads == 4)
        #expect(try m.stats().other == 0)
        #expect(try m.stats().triangles == 0)
        // Two loops dissolved per family on a 4-cell span.
        #expect(report.dissolvedLoops == 4)
    }

    /// Halving an already-halved cage used to strand a vertex. The cause was not
    /// in this algorithm at all: every scan that enumerates elements by probing
    /// ids was bounded by `live * 2 + 64`, and stable ids are SPARSE. Measured on
    /// this very mesh — 40 live edges with live ids up to 143; the next dissolve
    /// dropped it to 32 live, putting the ceiling at 128 and hiding every edge
    /// above it, including both remaining edges of the vertex that stranded.
    /// Scans now run to `Mesh.edgeCapacity`.
    @Test("an 8x8 grid halves to 4x4, and halves again to 2x2")
    func repeatedHalvingSteppsDown() throws {
        let m = try grid(cells: 8)
        #expect(m.faceCount == 64)
        try m.halveDensity()
        #expect(m.faceCount == 16)
        #expect(try m.stats().quads == 16)
        // A clean 4x4 grid has 25 vertices. More means the first halve already
        // left a mid-side vertex behind, which is what the second one trips on.
        #expect(m.vertexCount == 25, "after one halve: \(m.vertexCount) vertices")
        try m.halveDensity()
        #expect(m.faceCount == 4)
        let rings = m.liveFaceIDs().map { m.faceVertices($0).count }.sorted()
        let stats = try m.stats()
        #expect(
            stats.quads == 4,
            """
            rings=\(rings) vertices=\(m.vertexCount) \
            quads=\(stats.quads) tris=\(stats.triangles) other=\(stats.other)
            positions=\(positions(of: m).map { "(\($0.x),\($0.y))" }.sorted())
            """
        )
    }

    /// A 4x4 grid with SPACING 2 — the same shape a once-halved 8x8 has, but built
    /// fresh from OBJ. If this passes while halving an already-halved cage fails,
    /// the fault is in the post-halve mesh state, not in the algorithm.
    @Test("a grid with non-unit spacing halves the same way")
    func spacedGridHalves() throws {
        var lines: [String] = []
        for y in 0...4 {
            for x in 0...4 { lines.append("v \(x * 2) \(y * 2) 0") }
        }
        for y in 0..<4 {
            for x in 0..<4 {
                let a = y * 5 + x + 1
                lines.append("f \(a) \(a + 1) \(a + 6) \(a + 5)")
            }
        }
        let m = try mesh(fromOBJ: lines.joined(separator: "\n"))
        #expect(m.faceCount == 16)
        try m.halveDensity()
        #expect(m.faceCount == 4)
        #expect(try m.stats().quads == 4)
        #expect(m.vertexCount == 9)
    }

    /// Does a halved cage still have CONSISTENT winding? The engine's loop walk
    /// picks the "topologically opposite" edge from face ring order, so if the
    /// dissolve+merge leaves two faces traversing their shared edge the same way,
    /// a loop walk can turn a corner — and dissolving such a "loop" strands the
    /// vertex where it crosses itself. This is the diagnosis for halving a cage
    /// that was already halved.
    @Test("a halved cage keeps consistent face winding")
    func halvedCageKeepsConsistentWinding() throws {
        let m = try grid(cells: 8)
        try m.halveDensity()

        var traversals: [String: [String]] = [:]
        for face in m.liveFaceIDs() {
            let ring = m.faceVertices(face)
            for index in 0..<ring.count {
                let a = ring[index], b = ring[(index + 1) % ring.count]
                let key = a < b ? "\(a)-\(b)" : "\(b)-\(a)"
                traversals[key, default: []].append("\(a)->\(b)")
            }
        }
        let inconsistent = traversals.filter { _, directions in
            directions.count == 2 && directions[0] == directions[1]
        }
        #expect(
            inconsistent.isEmpty,
            "edges traversed the SAME way by both faces: \(inconsistent.keys.sorted())"
        )
    }

    @Test("the silhouette does not move: every surviving vertex was already there")
    func silhouetteIsPreserved() throws {
        let m = try grid(cells: 4)
        let before = Set(positions(of: m).map { "\($0.x),\($0.y),\($0.z)" })

        try m.halveDensity()

        for position in positions(of: m) {
            #expect(
                before.contains("\(position.x),\(position.y),\(position.z)"),
                "\(position) is not a position the cage had before — something moved"
            )
        }
        // The patch's four corners survive, so the outline is unchanged.
        for corner in [SIMD3<Float>(0, 0, 0), SIMD3(4, 0, 0), SIMD3(4, 4, 0), SIMD3(0, 4, 0)] {
            #expect(
                m.nearestVertex(to: corner, maxDistance: 1e-4) != nil,
                "corner \(corner) was lost"
            )
        }
        // And the survivors are exactly the even lattice lines (0, 2, 4).
        for position in positions(of: m) {
            #expect(position.x.truncatingRemainder(dividingBy: 2) == 0)
            #expect(position.y.truncatingRemainder(dividingBy: 2) == 0)
        }
    }

    @Test("no valence-2 leftovers: the merged faces really are quads")
    func noDanglingMidSideVertices() throws {
        let m = try grid(cells: 4)
        try m.halveDensity()
        // Every face is a 4-ring, and every ring vertex is a lattice corner: a
        // surviving mid-side vertex would show up as a 5- or 6-ring here.
        for face in m.liveFaceIDs() {
            let ring = m.faceVertices(face)
            #expect(ring.count == 4, "face \(face) has \(ring.count) sides")
        }
    }

    @Test("halving is deterministic")
    func halvingIsDeterministic() throws {
        let first = try grid(cells: 4)
        let second = try grid(cells: 4)
        try first.halveDensity()
        try second.halveDensity()
        #expect(first.positions() == second.positions())
        #expect(first.faceCount == second.faceCount)
    }

    // MARK: - Refusals (mesh untouched)

    @Test("a cage with a triangle is refused")
    func triangleIsRefused() throws {
        // A 2x2 grid with one cell split into triangles.
        let m = try mesh(fromOBJ: """
        v 0 0 0
        v 1 0 0
        v 2 0 0
        v 0 1 0
        v 1 1 0
        v 2 1 0
        v 0 2 0
        v 1 2 0
        v 2 2 0
        f 1 2 5 4
        f 2 3 6 5
        f 4 5 8 7
        f 5 6 9
        f 5 9 8
        """)
        let faces = m.faceCount
        #expect(throws: Mesh.HalveDensityFailure.notQuadOnly) { try m.halveDensity() }
        #expect(m.faceCount == faces, "a refusal must leave the cage untouched")
    }

    @Test("an ODD cell span is refused — every other loop has no consistent answer")
    func oddCellSpanIsRefused() throws {
        let m = try grid(cells: 3)
        let faces = m.faceCount
        let vertices = m.vertexCount
        #expect(throws: Mesh.HalveDensityFailure.oddCellCount) { try m.halveDensity() }
        #expect(m.faceCount == faces)
        #expect(m.vertexCount == vertices, "not even a partial halving may land")
    }

    @Test("a single quad is refused: nothing to halve")
    func singleQuadIsRefused() throws {
        let m = try grid(cells: 1)
        #expect(throws: Mesh.HalveDensityFailure.tooFewCells) { try m.halveDensity() }
        #expect(m.faceCount == 1)
    }

    @Test("an empty cage is refused")
    func emptyCageIsRefused() throws {
        let m = try Mesh()
        #expect(throws: Mesh.HalveDensityFailure.noCage) { try m.halveDensity() }
    }

    @Test("a POLE is refused: the loop through it cannot be walked end to end")
    func poleIsRefused() throws {
        // A 4x4 grid whose centre vertex is replaced by a triangle fan would not be
        // quad-only, so instead: three quads meeting at one interior vertex (an
        // L-shaped patch), which gives that vertex valence 3 with all edges
        // interior — a pole by the definition the loop walk cares about.
        let m = try mesh(fromOBJ: """
        v 0 0 0
        v 1 0 0
        v 2 0 0
        v 0 1 0
        v 1 1 0
        v 2 1 0
        v 0 2 0
        v 1 2 0
        v 2 2 0
        v 3 0 0
        v 3 1 0
        f 1 2 5 4
        f 2 3 6 5
        f 4 5 8 7
        f 5 6 9 8
        f 3 10 11 6
        """)
        let faces = m.faceCount
        // Either refusal is correct here — what must NOT happen is a partial
        // halving — so the assertion is on the mesh, with the error surfaced.
        var thrown: Error?
        do {
            try m.halveDensity()
        } catch {
            thrown = error
        }
        #expect(thrown != nil, "an irregular cage must be refused, not halved")
        #expect(m.faceCount == faces, "a refusal must leave the cage untouched")
    }





    /// The invariant the halving (and every other id-probing scan) rests on: the
    /// id CAPACITY is a sufficient bound, and the live COUNT is not. On an edited
    /// cage the two diverge — that divergence is what stranded a vertex here.
    @Test("edgeCapacity bounds the sparse id space; the live count does not")
    func capacityBoundsTheIdSpace() throws {
        let m = try grid(cells: 8)
        try m.halveDensity()

        var found = 0
        var highest = 0
        for id in UInt32(0)..<UInt32(m.edgeCapacity) where m.edgeEndpoints(of: id) != nil {
            found += 1
            highest = Int(id)
        }
        #expect(found == m.edgeCount, "capacity-bounded scan found \(found) of \(m.edgeCount)")
        // And the old bound would NOT have been enough after the next dissolve:
        // it is derived from the live count, which keeps falling as ids climb.
        #expect(
            highest >= m.edgeCount,
            """
            ids are dense here (highest \(highest), live \(m.edgeCount)) — this fixture no \
            longer exercises sparsity, so the guard above proves nothing
            """
        )
    }
}

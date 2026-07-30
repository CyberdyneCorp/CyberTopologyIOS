import CyberKit
import Foundation
import Testing
import simd

/// Rim bridge (openspec add-stroke-rim-bridge; spec: pencil-interaction / "A
/// stroke across a gap bridges the two facing rims with quads"): one
/// corresponding pair of rim vertices fills the corridor between their two rims
/// with quads, walking outward past the pair itself.
///
/// Public-API + inline OBJ fixtures, so this suite runs on DEVICE too (mirrored
/// into the app-hosted target in project.yml).
@Suite("Rim bridge ops")
struct RimBridgeOpsTests {
    private func mesh(fromOBJ text: String) throws -> Mesh {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rimbridge-\(UUID().uuidString).obj")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Mesh.loadOBJ(at: url)
    }

    /// Two 3-quad strips facing each other across a gap of `gap` units, with
    /// unit cells. The rims facing the gap are y = 0 (lower strip, vertices
    /// 8...11) and y = gap (upper strip, vertices 0...3).
    ///
    ///   v4 v5 v6 v7      y = gap + 1
    ///   v0 v1 v2 v3      y = gap        <- upper rim
    ///        (gap)
    ///   v8 v9 v10 v11    y = 0          <- lower rim
    ///   v12 …    v15     y = -1
    private func facingStrips(gap: Float) throws -> Mesh {
        var lines: [String] = []
        for y in [gap, gap + 1, 0, -1] {
            for x in 0...3 { lines.append("v \(x) \(y) 0") }
        }
        // 1-based OBJ indices: upper strip 1...8, lower strip 9...16.
        for base in [1, 9] {
            for column in 0..<3 {
                let a = base + column
                lines.append("f \(a) \(a + 1) \(a + 5) \(a + 4)")
            }
        }
        return try mesh(fromOBJ: lines.joined(separator: "\n"))
    }

    /// 2x2 quads over a 3x3 vertex lattice — vertex 4 is INTERIOR (no rim).
    private func grid2x2() throws -> Mesh {
        var lines: [String] = []
        for y in 0...2 {
            for x in 0...2 { lines.append("v \(x) \(y) 0") }
        }
        lines += ["f 1 2 5 4", "f 2 3 6 5", "f 4 5 8 7", "f 5 6 9 8"]
        return try mesh(fromOBJ: lines.joined(separator: "\n"))
    }

    private func positions(of mesh: Mesh, _ vertices: [UInt32]) -> [SIMD3<Float>] {
        vertices.compactMap { mesh.vertexPosition($0) }
    }

    // MARK: - The corridor fill

    @Test("one pair fills the whole corridor: a quad per paired step, past the pair")
    func bridgeFillsCorridorBeyondTheAnchors() throws {
        let m = try facingStrips(gap: 1)
        let before = m.faceCount
        // Anchors are the LEFTMOST vertex of each rim, so everything the fill
        // covers beyond column 0 is the walk extending past the pair.
        let bridge = try m.bridgeRims(from: 0, to: 8)
        #expect(bridge.columns == 3, "the walk should reach the end of both rims")
        #expect(bridge.rows == 1, "a one-cell gap is one row")
        #expect(bridge.faces.count == 3)
        #expect(m.faceCount == before + 3)
        // Every bridge face is a quad.
        for face in bridge.faces {
            #expect(m.faceVertices(face).count == 4)
        }
    }

    @Test("the pair is a correspondence, not an extent: the fill fans out both ways")
    func bridgeFansOutBothWaysFromTheAnchors() throws {
        let m = try facingStrips(gap: 1)
        // Anchor mid-rim (x = 1 on both rims): one column lies to the left of the
        // pair and two to the right. A one-directional walk would fill only one
        // side and leave the rest of the corridor open.
        let bridge = try m.bridgeRims(from: 1, to: 9)
        #expect(bridge.columns == 3, "both sides of the anchor pair should fill")
        #expect(bridge.faces.count == 3)
        // The corridor is covered end to end: the bridge quads between them use
        // every vertex of both rims, not just the ones to one side of the pair.
        let covered = Set(bridge.faces.flatMap { m.faceVertices($0) })
        #expect(covered == Set([0, 1, 2, 3, 8, 9, 10, 11]))
        // And every rim edge between the strips is now interior — nothing left free.
        for pair in [(UInt32(0), UInt32(1)), (1, 2), (2, 3), (8, 9), (9, 10), (10, 11)] {
            let a = try #require(m.vertexPosition(pair.0))
            let b = try #require(m.vertexPosition(pair.1))
            let edge = try #require(m.nearestEdge(to: (a + b) * 0.5, maxDistance: 0.1)?.edge)
            #expect(m.isBoundaryEdge(edge) == false, "rim edge \(pair) should be bridged")
        }
    }

    @Test("a single-row bridge reuses rim vertices and adds none")
    func singleRowBridgeAddsNoVertices() throws {
        let m = try facingStrips(gap: 1)
        let rims: [UInt32] = [0, 1, 2, 3, 8, 9, 10, 11]
        let rimPositionsBefore = positions(of: m, rims)
        let vertexCountBefore = m.vertexCount

        let bridge = try m.bridgeRims(from: 0, to: 8)
        #expect(bridge.newVertices.isEmpty, "a one-row bridge is built from rim vertices only")
        #expect(m.vertexCount == vertexCountBefore)
        // Rim vertices are reused, never moved.
        #expect(positions(of: m, rims) == rimPositionsBefore)
        // Each bridge quad's corners are all pre-existing rim vertices.
        let rimSet = Set(rims)
        for face in bridge.faces {
            #expect(m.faceVertices(face).allSatisfy { rimSet.contains($0) })
        }
    }

    @Test("a multi-cell gap subdivides into cage-sized rows, sharing each interior vertex once")
    func wideGapSubdividesIntoRows() throws {
        // Cells are 1 unit, the gap is 3 → three rows of roughly square quads.
        let m = try facingStrips(gap: 3)
        let rims: [UInt32] = [0, 1, 2, 3, 8, 9, 10, 11]
        let rimPositionsBefore = positions(of: m, rims)

        let bridge = try m.bridgeRims(from: 0, to: 8)
        #expect(bridge.rows == 3, "a 3-cell gap is three rows, not one stretched quad")
        #expect(bridge.columns == 3)
        #expect(bridge.faces.count == 9)
        // Two interior rows of four vertices each — created ONCE and shared by
        // their four quads. A broken slot→id mapping would create duplicates
        // here (up to 4 per interior vertex) and tear the strip.
        #expect(bridge.newVertices.count == 8, "interior rows: 2 x 4 shared vertices")
        #expect(Set(bridge.newVertices).count == 8)
        #expect(m.vertexCount == 16 + 8)
        #expect(positions(of: m, rims) == rimPositionsBefore, "rim vertices must not move")
        // The interior rows land on the interpolated grid (no snapper here, so
        // exactly: y = 1 and y = 2 across x = 0...3).
        let interior = positions(of: m, bridge.newVertices)
        #expect(interior.allSatisfy { abs($0.y - 1) < 1e-4 || abs($0.y - 2) < 1e-4 })
        // Every quad is a quad, and the strip is manifold across the rows: an
        // interior vertex is shared by four faces, an interior rim vertex by
        // three (its own strip's quads plus the bridge).
        for face in bridge.faces {
            #expect(m.faceVertices(face).count == 4)
        }
    }

    /// The device case (2026-07-29, 49v/34f cage): the recognizer read the stroke
    /// as `bridgeRims [vertex:27,vertex:18]` and the mesh did not change.
    ///
    /// The notch the artist crossed is closed on one side by a wall that is itself
    /// SUBDIVIDED — the block behind it has two rows, so a rim vertex sits at the
    /// wall's mid-height. Both rails step onto the wall's two ends, and the span
    /// between them runs straight through that mid vertex, which the walk read as
    /// occupied topology and stopped on — with zero steps taken, leaving nothing
    /// to build.
    ///
    ///   (0,2)---(1,2)---(2,2)A      the notch is x 1..2, y 0..2: two cells tall,
    ///     |       |       |         one wide, open to the right. Its left wall
    ///     |     (1,1)     :         (x = 1) carries the mid vertex (1,1).
    ///     |       |       :
    ///   (0,0)---(1,0)---(2,0)B
    private func notchWithSubdividedWall() throws -> Mesh {
        try mesh(fromOBJ: """
        v 0 0 0
        v 1 0 0
        v 0 1 0
        v 1 1 0
        v 0 2 0
        v 1 2 0
        v 2 2 0
        v 1 3 0
        v 2 3 0
        v 1 -1 0
        v 2 -1 0
        v 2 0 0
        f 1 2 4 3
        f 3 4 6 5
        f 6 7 9 8
        f 10 11 12 2
        """)
    }

    @Test("a notch whose wall is subdivided still bridges, welding onto the wall vertex")
    func notchWithSubdividedWallBridges() throws {
        let m = try notchWithSubdividedWall()
        let facesBefore = m.faceCount
        // A = (2,2) is vertex 6, B = (2,0) is vertex 11 (0-based).
        let a = try #require(m.nearestVertex(to: SIMD3(2, 2, 0), maxDistance: 1e-3)?.vertex)
        let b = try #require(m.nearestVertex(to: SIMD3(2, 0, 0), maxDistance: 1e-3)?.vertex)
        let wall = try #require(m.nearestVertex(to: SIMD3(1, 1, 0), maxDistance: 1e-3)?.vertex)

        let bridge = try m.bridgeRims(from: a, to: b)
        // One column (the walk meets the wall), two rows (the gap is two cells).
        #expect(bridge.columns == 1)
        #expect(bridge.rows == 2)
        #expect(bridge.faces.count == 2)
        #expect(m.faceCount == facesBefore + 2)
        // The row lands ON the wall's mid vertex, so it is REUSED, not duplicated:
        // exactly one new vertex (the row's own point out on the open side).
        #expect(bridge.newVertices.count == 1)
        #expect(m.vertexCount == 12 + 1)
        // The wall vertex came off the RIM PATH, not off a radius search around an
        // interpolated point: it is the wall's own vertex at its own position.
        #expect(m.vertexPosition(wall) == SIMD3(1, 1, 0))
        // Both bridge quads reference the wall vertex — no T-junction against it.
        let touching = bridge.faces.filter { m.faceVertices($0).contains(wall) }
        #expect(
            touching.count == 2,
            "the wall's mid vertex must be a corner of both bridge quads, not stranded"
        )
    }

    /// The curvature half of the second device report: `+6 v` where two were needed
    /// means NO weld happened, on any column. A real cage is domed, so the straight
    /// chord between a wall's two ends bows away from the wall's own vertices — far
    /// enough that a radius search around the interpolated point misses them and
    /// creates duplicates, leaving the wall cracked against the bridge.
    ///
    /// Here the wall bows to (1.6, 1): 0.6 from the chord midpoint, well past any
    /// sane weld radius. Only reading the interior rows off the RIM PATH finds it.
    private func notchWithBowedWall() throws -> Mesh {
        try mesh(fromOBJ: """
        v 0 0 0
        v 1 0 0
        v 0 1 0
        v 1.6 1 0
        v 0 2 0
        v 1 2 0
        v 2 2 0
        v 1 3 0
        v 2 3 0
        v 1 -1 0
        v 2 -1 0
        v 2 0 0
        f 1 2 4 3
        f 3 4 6 5
        f 6 7 9 8
        f 10 11 12 2
        """)
    }

    @Test("a BOWED wall's vertex is still reused — the rows come off the rim, not a radius")
    func bowedWallVertexIsReused() throws {
        let m = try notchWithBowedWall()
        let a = try #require(m.nearestVertex(to: SIMD3(2, 2, 0), maxDistance: 1e-3)?.vertex)
        let b = try #require(m.nearestVertex(to: SIMD3(2, 0, 0), maxDistance: 1e-3)?.vertex)
        let wall = try #require(m.nearestVertex(to: SIMD3(1.6, 1, 0), maxDistance: 1e-3)?.vertex)

        let bridge = try m.bridgeRims(from: a, to: b)
        #expect(bridge.rows == 2, "the wall's own subdivision sets the row count")
        #expect(bridge.faces.count == 2)
        // ONE new vertex (the row out on the open side), NOT two: the bowed wall's
        // vertex was reused where a radius search would have duplicated it.
        #expect(bridge.newVertices.count == 1)
        #expect(m.vertexPosition(wall) == SIMD3(1.6, 1, 0), "the wall vertex must not move")
        let touching = bridge.faces.filter { m.faceVertices($0).contains(wall) }
        #expect(touching.count == 2, "the bowed wall vertex is a corner of both quads")
    }

    /// Second device report (2026-07-29, same cage): the notch DID fill — three
    /// rows welded onto the wall's own subdivisions — but the walk then carried on
    /// in the OTHER direction, where the corridor does not continue, and stitched
    /// three skewed quads across bare Target (`+6 f` where the notch is 3).
    ///
    /// Past the anchors the upper rim TURNS UP the gap while the lower one still
    /// runs across it. Both the parallel test (the two steps still had a positive
    /// dot on the curved surface) and the divergence bound (1.4x the first gap)
    /// passed, so nothing stopped it. A rail stepping along the gap is the signal:
    /// the rim has stopped bounding the corridor.
    ///
    ///   (0,2)---(1,2)---(2,2)A--(2.2,3) rim turns UP the gap
    ///     |       |       |         :
    ///     |     (1,1)     :          :  open Target — nothing to bridge
    ///     |       |       :           :
    ///   (0,0)---(1,0)---(2,0)B---(3,0.3) rim runs across
    private func notchWithRimsFoldingAway() throws -> Mesh {
        try mesh(fromOBJ: """
        v 0 0 0
        v 1 0 0
        v 0 1 0
        v 1 1 0
        v 0 2 0
        v 1 2 0
        v 2 2 0
        v 1 3 0
        v 2.2 3 0
        v 1 -1 0
        v 2 -1 0
        v 2 0 0
        v 3 0.3 0
        v 3 -0.7 0
        f 1 2 4 3
        f 3 4 6 5
        f 6 7 9 8
        f 10 11 12 2
        f 12 13 14 11
        """)
    }

    @Test("the walk stops where the rims fold away instead of stitching over open surface")
    func rimsFoldingAwayStopTheWalk() throws {
        let m = try notchWithRimsFoldingAway()
        let a = try #require(m.nearestVertex(to: SIMD3(2, 2, 0), maxDistance: 1e-3)?.vertex)
        let b = try #require(m.nearestVertex(to: SIMD3(2, 0, 0), maxDistance: 1e-3)?.vertex)
        // The vertices the fold leads to: a quad reaching either of them would be
        // spanning open Target, which is what this guard exists to prevent.
        let foldA = try #require(m.nearestVertex(to: SIMD3(2.2, 3, 0), maxDistance: 1e-3)?.vertex)
        let foldB = try #require(m.nearestVertex(to: SIMD3(3, 0.3, 0), maxDistance: 1e-3)?.vertex)

        let bridge = try m.bridgeRims(from: a, to: b)
        #expect(bridge.columns == 1, "only the notch is a corridor")
        #expect(bridge.faces.count == bridge.rows)
        for face in bridge.faces {
            let ring = m.faceVertices(face)
            #expect(!ring.contains(foldA), "a bridge quad must not reach past the fold")
            #expect(!ring.contains(foldB), "a bridge quad must not reach past the fold")
        }
    }

    // MARK: - Where the walk stops

    @Test("diverging rims stop the walk instead of stitching a fan")
    func divergingRimsStopTheWalk() throws {
        // Upper rim flat at y = 2; the lower rim falls away, so the pair gap grows
        // 2 → 3 → 4.5 → 8 and passes the divergence bound (2.5x the first gap) at
        // the LAST pair: two columns are bridged, then the walk stops rather than
        // stitching a fan across a corridor that is no longer one.
        let m = try mesh(fromOBJ: """
        v 0 2 0
        v 1 2 0
        v 2 2 0
        v 3 2 0
        v 0 3 0
        v 1 3 0
        v 2 3 0
        v 3 3 0
        v 0 0 0
        v 1 -1 0
        v 2 -2.5 0
        v 3 -6 0
        v 0 -1 0
        v 1 -2 0
        v 2 -3.5 0
        v 3 -7 0
        f 1 2 6 5
        f 2 3 7 6
        f 3 4 8 7
        f 9 10 14 13
        f 10 11 15 14
        f 11 12 16 15
        """)
        let bridge = try m.bridgeRims(from: 0, to: 8)
        #expect(bridge.columns == 2, "the walk stops where the rims stop facing each other")
        #expect(bridge.faces.count == 2 * bridge.rows)
    }

    @Test("the walk is bounded by maximumColumns")
    func walkIsBounded() throws {
        let m = try facingStrips(gap: 1)
        let bridge = try m.bridgeRims(from: 0, to: 8, maximumColumns: 1)
        #expect(bridge.columns == 1)
        #expect(bridge.faces.count == 1)
    }

    @Test("row count is bounded by maximumRows")
    func rowsAreBounded() throws {
        let m = try facingStrips(gap: 3)
        let bridge = try m.bridgeRims(from: 0, to: 8, maximumRows: 2)
        #expect(bridge.rows == 2)
    }

    // MARK: - Refusals (mesh untouched)

    @Test("a vertex with no open rim is refused")
    func interiorVertexIsRefused() throws {
        let m = try grid2x2()
        let faces = m.faceCount
        // Vertex 4 is the lattice centre: every incident edge has two faces.
        #expect(throws: Mesh.RimBridgeFailure.notOnOpenRim(4)) {
            try m.bridgeRims(from: 4, to: 0)
        }
        #expect(m.faceCount == faces, "a refused bridge leaves the mesh unchanged")
    }

    @Test("two vertices already sharing an edge have no gap to bridge")
    func adjacentVerticesAreRefused() throws {
        let m = try facingStrips(gap: 1)
        let faces = m.faceCount
        #expect(throws: Mesh.RimBridgeFailure.noGap) {
            try m.bridgeRims(from: 0, to: 1)
        }
        #expect(m.faceCount == faces)
    }

    @Test("two points along the SAME rim stretch are refused, not bridged over the strip")
    func sameRimStretchIsRefused() throws {
        // 0 and 3 are both on the upper rim, three edges apart. Every other
        // condition holds — both are rim vertices, they share no edge, and one
        // pair of walk directions (up both ends of the strip) runs parallel — so
        // without the corridor test this bridged ONE quad straight over the
        // existing three.
        let m = try facingStrips(gap: 1)
        let faces = m.faceCount
        #expect(throws: Mesh.RimBridgeFailure.noCorridor) {
            try m.bridgeRims(from: 0, to: 3)
        }
        #expect(m.faceCount == faces)
    }

    @Test("a bridge is journal-ready: same input, same result")
    func bridgeIsDeterministic() throws {
        let first = try facingStrips(gap: 3)
        let second = try facingStrips(gap: 3)
        let a = try first.bridgeRims(from: 0, to: 8)
        let b = try second.bridgeRims(from: 0, to: 8)
        #expect(a == b)
        #expect(first.positions() == second.positions())
    }
}

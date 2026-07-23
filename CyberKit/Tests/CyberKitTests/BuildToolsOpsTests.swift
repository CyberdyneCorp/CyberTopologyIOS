import CyberKit
import CyberKitTesting
import Foundation
import Testing
import simd

/// Task 4.1 engine patches 0016/0017: the build-tool mesh operations
/// exercised through the CyberKit facade against real engine meshes —
/// mixed-ring face building (Build Quad / Build Triangle), boundary-edge
/// growth (triangle → quad), edge-face adjacency, shortest vertex paths,
/// arc-length path distribution, and the segment-restricted surface cut
/// with auto-triangulated n-gons. Deterministic results are golden-filed
/// (spec: quality-assurance / "Determinism and golden-file regression
/// tests").
@Suite("Build tool mesh ops (engine)")
struct BuildToolsOpsTests {
    // MARK: - Fixtures

    private func mesh(fromOBJ text: String) throws -> Mesh {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("build-ops-\(UUID().uuidString).obj")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Mesh.loadOBJ(at: url)
    }

    /// One unit quad on z = 0 (engine vertex ids 0-3, ring order).
    private func singleQuad() throws -> Mesh {
        try mesh(fromOBJ: """
        v 0 0 0
        v 1 0 0
        v 1 1 0
        v 0 1 0
        f 1 2 3 4
        """)
    }

    /// One triangle (ids 0-2).
    private func singleTriangle() throws -> Mesh {
        try mesh(fromOBJ: """
        v 0 0 0
        v 1 0 0
        v 0.5 1 0
        f 1 2 3
        """)
    }

    /// The committed 3x2 quad grid strip (columns at x in {-0.375, -0.125,
    /// 0.125, 0.375}, rows at y in {-0.25, 0, 0.25}; ids row-major 0-11).
    private func grid32() throws -> Mesh {
        let url = try #require(Bundle.module.url(
            forResource: "grid32", withExtension: "obj", subdirectory: "Fixtures"
        ))
        return try Mesh.loadOBJ(at: url)
    }

    /// Flat plane target at z = 0.25 for snap assertions.
    private func planeSnapper() throws -> SurfaceSnapper {
        try SurfaceSnapper(target: mesh(fromOBJ: """
        v -10 -10 0.25
        v 10 -10 0.25
        v 10 10 0.25
        v -10 10 0.25
        f 1 2 3 4
        """))
    }

    private var goldensDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Goldens", isDirectory: true)
            .appendingPathComponent("MeshEdits", isDirectory: true)
    }

    private func edge(
        of mesh: Mesh, near point: SIMD3<Float>, radius: Float = 0.01
    ) throws -> UInt32 {
        try #require(mesh.nearestEdge(to: point, maxDistance: radius)).edge
    }

    // MARK: - Edge-face adjacency query (patch 0016)

    @Test("edgeFaces reports adjacency with ring sizes; dead ids are empty")
    func edgeFacesReportsAdjacencyAndSizes() throws {
        let grid = try grid32()
        // Boundary edge (bottom-left horizontal, v0-v1): one quad.
        let boundary = try edge(of: grid, near: SIMD3(-0.25, -0.25, 0))
        let boundaryFaces = grid.edgeFaces(of: boundary)
        #expect(boundaryFaces.count == 1)
        #expect(boundaryFaces.first?.sides == 4)
        // Interior vertical edge (v1-v5) between the two bottom-row quads.
        let interior = try edge(of: grid, near: SIMD3(-0.125, -0.125, 0))
        let interiorFaces = grid.edgeFaces(of: interior)
        #expect(interiorFaces.count == 2)
        #expect(interiorFaces.allSatisfy { $0.sides == 4 })
        // Dead id.
        #expect(grid.edgeFaces(of: 4_000_000).isEmpty)
    }

    // MARK: - buildFace (patch 0016)

    @Test("buildFace tents a triangle off a quad's boundary edge, welded and golden-filed")
    func buildFaceTentsTriangleOffQuadEdge() throws {
        let quad = try singleQuad()
        let built = try quad.buildFace(ring: [
            .existing(0), .existing(1), .point(SIMD3(0.5, -1, 0)),
        ])
        #expect(quad.faceCount == 2)
        #expect(quad.vertexCount == 5)
        #expect(built.newVertices.count == 1)
        #expect(Set(built.ringVertices).isSuperset(of: [0, 1]))
        // Welded: the shared edge 0-1 now borders BOTH faces.
        let shared = try edge(of: quad, near: SIMD3(0.5, 0, 0))
        #expect(quad.edgeFaces(of: shared).count == 2)
        let golden = goldensDirectory
            .appendingPathComponent("build_face_tent.payload.golden")
        try GoldenFile.compare(try quad.payloadData(), golden: golden)
    }

    @Test("buildFace winds the welded face opposite its neighbor (coherent normals)")
    func buildFaceWindsAgainstNeighbor() throws {
        let quad = try singleQuad()
        // Ring deliberately ordered ALONG the existing face's traversal
        // (0 -> 1 matches f 1 2 3 4): the engine must flip it.
        let built = try quad.buildFace(ring: [
            .existing(0), .existing(1), .point(SIMD3(0.5, -1, 0)),
        ])
        let apex = try #require(built.newVertices.first)
        // Flipped ring traverses 1 -> 0: apex first or ring reversed —
        // assert via the committed order (engine reports the FINAL ring).
        let ring = built.ringVertices
        let indexOf0 = try #require(ring.firstIndex(of: 0))
        let next = ring[(indexOf0 + 1) % ring.count]
        #expect(next != 1, "new face must traverse 0 -> 1 in reverse, ring: \(ring), apex \(apex)")
    }

    // MARK: - Gesture face welding (change simplify-gesture-grammar, task 4)

    /// Task 4.3 acceptance from the reference application's counts: a quad
    /// drawn adjacent to an existing quad, two of its corners on the shared
    /// edge, welds — +2 vertices, +3 edges, +1 face (6v / 7e / 2f), NOT a
    /// free-floating duplicate (+4 vertices, a disconnected face).
    @Test("createWeldedFace shares an edge with an adjacent quad (6v/7e/2f)")
    func weldedFaceSharesEdgeWithAdjacentQuad() throws {
        let quad = try singleQuad()
        #expect(quad.vertexCount == 4)
        #expect(quad.edgeCount == 4)
        #expect(quad.faceCount == 1)
        // Adjacent quad to the right; corners 0 and 3 sit on the existing
        // right edge, verts id1 (1,0,0) and id2 (1,1,0).
        let built = try quad.createWeldedFace(
            at: [SIMD3(1, 0, 0), SIMD3(2, 0, 0), SIMD3(2, 1, 0), SIMD3(1, 1, 0)],
            mergeRadius: 0.1
        )
        #expect(quad.vertexCount == 6, "expected +2 vertices, got \(quad.vertexCount)")
        #expect(quad.edgeCount == 7, "expected +3 edges, got \(quad.edgeCount)")
        #expect(quad.faceCount == 2, "expected +1 face, got \(quad.faceCount)")
        #expect(built.newVertices.count == 2)
        // The shared edge now borders BOTH faces — a real weld, not an
        // overlap.
        let shared = try edge(of: quad, near: SIMD3(1, 0.5, 0))
        #expect(quad.edgeFaces(of: shared).count == 2)
    }

    /// REGRESSION (device: welded quads twisted into a bowtie): a large,
    /// scene-relative mergeRadius on a big Target can exceed a small quad, so
    /// a corner welds to the WRONG distant vertex and twists the ring. Here
    /// the same adjacent quad is welded with a mergeRadius (3.0) far larger
    /// than the quad's unit edges: uncapped, corner (2,0) would weld to the
    /// existing (1,1) — a whole diagonal away — collapsing/twisting the face.
    /// The quad-relative cap keeps the weld to the shared edge only.
    @Test("createWeldedFace does not weld to a far vertex under a huge mergeRadius")
    func weldedFaceCapsMergeToQuadScale() throws {
        let quad = try singleQuad()
        let built = try quad.createWeldedFace(
            at: [SIMD3(1, 0, 0), SIMD3(2, 0, 0), SIMD3(2, 1, 0), SIMD3(1, 1, 0)],
            mergeRadius: 3.0
        )
        // Same clean weld as with a small radius: 6v / 7e / 2f, two new
        // corners, shared edge bordering both faces — NOT a collapsed ring.
        #expect(quad.vertexCount == 6, "wrong-vertex weld twisted the ring: \(quad.vertexCount) v")
        #expect(quad.edgeCount == 7)
        #expect(quad.faceCount == 2)
        #expect(built.newVertices.count == 2)
        let shared = try edge(of: quad, near: SIMD3(1, 0.5, 0))
        #expect(quad.edgeFaces(of: shared).count == 2)
    }

    /// Task 4.4 anti-vacuity: a quad drawn far from any topology still
    /// creates four new vertices and stays disconnected — the weld must not
    /// collapse an isolated quad onto unrelated geometry.
    @Test("createWeldedFace far from topology is a standalone quad (+4 vertices)")
    func weldedFaceFarFromTopologyIsStandalone() throws {
        let quad = try singleQuad()
        try quad.createWeldedFace(
            at: [SIMD3(10, 10, 0), SIMD3(11, 10, 0), SIMD3(11, 11, 0), SIMD3(10, 11, 0)],
            mergeRadius: 0.1
        )
        #expect(quad.vertexCount == 8, "4 original + 4 new")
        #expect(quad.faceCount == 2)
        // The original right edge still borders only its own face.
        let rightEdge = try edge(of: quad, near: SIMD3(1, 0.5, 0))
        #expect(quad.edgeFaces(of: rightEdge).count == 1)
    }

    /// The first stroke of a retopo: an empty mesh has nothing to weld to,
    /// so every corner is new.
    @Test("createWeldedFace on an empty mesh creates the first quad")
    func weldedFaceOnEmptyMeshCreatesStandalone() throws {
        let mesh = try Mesh()
        try mesh.createWeldedFace(
            at: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0)],
            mergeRadius: 0.1
        )
        #expect(mesh.vertexCount == 4)
        #expect(mesh.faceCount == 1)
    }

    @Test("buildFace corner quad: one existing vertex + three snapped points")
    func buildFaceCornerQuadSnapsNewPoints() throws {
        let quad = try singleQuad()
        let snapper = try planeSnapper()
        let built = try quad.buildFace(
            ring: [
                .existing(2), .point(SIMD3(2, 1, 3)), .point(SIMD3(2, 2, -1)),
                .point(SIMD3(1, 2, 0.7)),
            ],
            snapping: snapper
        )
        #expect(quad.faceCount == 2)
        #expect(built.newVertices.count == 3)
        for vertex in built.newVertices {
            let z = try #require(quad.vertexPosition(vertex)).z
            #expect(abs(z - 0.25) < 1e-5, "new vertex must snap onto the plane target")
        }
        // The reused corner keeps its position (only NEW points snap).
        #expect(try #require(quad.vertexPosition(2)).z == 0)
    }

    @Test("buildFace rejects dead ids, repeats, and degenerate rings, mesh untouched")
    func buildFaceRejectsInvalidRings() throws {
        let quad = try singleQuad()
        let before = try quad.payloadData()
        #expect(throws: CyberKitError.self) {
            try quad.buildFace(ring: [
                .existing(0), .existing(99), .point(SIMD3(0, -1, 0)),
            ])
        }
        #expect(throws: CyberKitError.self) {
            try quad.buildFace(ring: [
                .existing(0), .existing(0), .point(SIMD3(0, -1, 0)),
            ])
        }
        #expect(throws: CyberKitError.self) {
            // Coincident new point on an existing ring vertex.
            try quad.buildFace(ring: [
                .existing(0), .existing(1), .point(SIMD3(0, 0, 0)),
            ])
        }
        #expect(throws: CyberKitError.self) {
            try quad.buildFace(ring: [.existing(0), .existing(1)])
        }
        #expect(try quad.payloadData() == before)
    }

    // MARK: - growBoundaryEdge (patch 0016)

    @Test("growBoundaryEdge turns a triangle into a quad at the dragged point")
    func growBoundaryEdgeMakesQuad() throws {
        let tri = try singleTriangle()
        let seed = try edge(of: tri, near: SIMD3(0.5, 0, 0))  // bottom edge
        let vertex = try tri.growBoundaryEdge(seed, to: SIMD3(0.5, -1, 0))
        #expect(tri.faceCount == 1)
        #expect(tri.vertexCount == 4)
        #expect(try tri.stats().quads == 1)
        #expect(tri.vertexPosition(vertex) == SIMD3(0.5, -1, 0))
        let golden = goldensDirectory
            .appendingPathComponent("grow_boundary_edge.payload.golden")
        try GoldenFile.compare(try tri.payloadData(), golden: golden)
    }

    @Test("growBoundaryEdge rejects interior edges and non-triangle faces")
    func growBoundaryEdgeRejectsUnusableEdges() throws {
        let quad = try singleQuad()
        let before = try quad.payloadData()
        let boundary = try edge(of: quad, near: SIMD3(0.5, 0, 0))
        #expect(throws: CyberKitError.self) {
            // Boundary edge of a QUAD: growing would leave a pentagon.
            try quad.growBoundaryEdge(boundary, to: SIMD3(0.5, -1, 0))
        }
        #expect(try quad.payloadData() == before)

        let grid = try grid32()
        let gridBefore = try grid.payloadData()
        let interior = try edge(of: grid, near: SIMD3(-0.125, -0.125, 0))
        #expect(throws: CyberKitError.self) {
            try grid.growBoundaryEdge(interior, to: SIMD3(0, 0, 1))
        }
        #expect(try grid.payloadData() == gridBefore)
    }

    // MARK: - shortestVertexPath (patch 0017)

    @Test("shortestVertexPath walks the grid along edges, endpoints inclusive")
    func shortestVertexPathWalksGrid() throws {
        let grid = try grid32()
        // Bottom-left (0) to bottom-right (3): straight along the bottom row.
        #expect(grid.shortestVertexPath(from: 0, to: 3) == [0, 1, 2, 3])
        // Same vertex / dead ids: empty.
        #expect(grid.shortestVertexPath(from: 0, to: 0).isEmpty)
        #expect(grid.shortestVertexPath(from: 0, to: 4_000_000).isEmpty)
    }

    @Test("shortestVertexPath returns empty across disconnected components")
    func shortestVertexPathDisconnected() throws {
        let islands = try mesh(fromOBJ: """
        v 0 0 0
        v 1 0 0
        v 0.5 1 0
        v 5 0 0
        v 6 0 0
        v 5.5 1 0
        f 1 2 3
        f 4 5 6
        """)
        #expect(islands.shortestVertexPath(from: 0, to: 4).isEmpty)
    }

    // MARK: - distributePath (patch 0017)

    @Test("distributePath evens the chain spacing, endpoints fixed, golden-filed")
    func distributePathEvensSpacing() throws {
        // Bottom row with vertex 1 pushed far off-center.
        let strip = try mesh(fromOBJ: """
        v 0 0 0
        v 0.2 0 0
        v 2 0 0
        v 3 0 0
        v 0 1 0
        v 0.2 1 0
        v 2 1 0
        v 3 1 0
        f 1 2 6 5
        f 2 3 7 6
        f 3 4 8 7
        """)
        try strip.distributePath([0, 1, 2, 3])
        let p0 = try #require(strip.vertexPosition(0))
        let p1 = try #require(strip.vertexPosition(1))
        let p2 = try #require(strip.vertexPosition(2))
        let p3 = try #require(strip.vertexPosition(3))
        #expect(p0 == SIMD3(0, 0, 0))  // endpoints fixed
        #expect(p3 == SIMD3(3, 0, 0))
        let d01 = simd_distance(p0, p1)
        let d12 = simd_distance(p1, p2)
        let d23 = simd_distance(p2, p3)
        #expect(abs(d01 - d12) < 1e-4)
        #expect(abs(d12 - d23) < 1e-4)
        let golden = goldensDirectory
            .appendingPathComponent("distribute_path.payload.golden")
        try GoldenFile.compare(try strip.payloadData(), golden: golden)
    }

    @Test("distributePath snaps moved vertices onto the Target")
    func distributePathSnapsToTarget() throws {
        let strip = try mesh(fromOBJ: """
        v 0 0 0
        v 0.2 0 0
        v 2 0 0
        v 0 1 0
        v 0.2 1 0
        v 2 1 0
        f 1 2 5 4
        f 2 3 6 5
        """)
        try strip.distributePath([0, 1, 2], snapping: try planeSnapper())
        // Interior vertex moved AND snapped onto z = 0.25; endpoints fixed.
        #expect(abs(try #require(strip.vertexPosition(1)).z - 0.25) < 1e-5)
        #expect(try #require(strip.vertexPosition(0)).z == 0)
    }

    @Test("distributePath rejects short, dead, repeated, and broken chains untouched")
    func distributePathRejectsInvalidChains() throws {
        let grid = try grid32()
        let before = try grid.payloadData()
        #expect(throws: CyberKitError.self) { try grid.distributePath([0, 1]) }
        #expect(throws: CyberKitError.self) { try grid.distributePath([0, 1, 400]) }
        #expect(throws: CyberKitError.self) { try grid.distributePath([0, 1, 0]) }
        // 0 and 5 are diagonal — no edge joins them.
        #expect(throws: CyberKitError.self) { try grid.distributePath([0, 5, 6]) }
        #expect(try grid.payloadData() == before)
    }

    // MARK: - surfaceCut (patch 0017)

    @Test("surfaceCut splits crossed edges and faces along the knife segment, golden-filed")
    func surfaceCutSplitsAlongSegment() throws {
        let grid = try grid32()
        // Vertical knife through the middle of the LEFT column only
        // (x = -0.25): crosses that column's three horizontal edge rows.
        let counts = try grid.surfaceCut(
            from: SIMD3(-0.25, -0.35, 0), to: SIMD3(-0.25, 0.35, 0),
            viewDirection: SIMD3(0, 0, -1)
        )
        #expect(counts.splitEdges == 3)  // bottom, middle, top rows of column 0
        #expect(counts.splitFaces == 2)  // both left-column quads split
        #expect(grid.vertexCount == 15)
        #expect(grid.faceCount == 8)
        // All-quad result here: the cut lands vertex-to-vertex on each face.
        #expect(try grid.stats().quads == 8)
        let golden = goldensDirectory
            .appendingPathComponent("surface_cut_grid32.payload.golden")
        try GoldenFile.compare(try grid.payloadData(), golden: golden)
    }

    @Test("surfaceCut is restricted to the segment's extent")
    func surfaceCutRespectsSegmentExtent() throws {
        let grid = try grid32()
        // Same knife line but only spanning the bottom half: the top edge
        // row (y = 0.25) of the left column must NOT split.
        let counts = try grid.surfaceCut(
            from: SIMD3(-0.25, -0.35, 0), to: SIMD3(-0.25, 0.05, 0),
            viewDirection: SIMD3(0, 0, -1)
        )
        #expect(counts.splitEdges == 2)  // bottom + middle rows only
        #expect(counts.splitFaces == 1)  // only the bottom-left quad carries 2 cut verts
    }

    @Test("surfaceCut auto-triangulates resulting n-gons")
    func surfaceCutTriangulatesNGons() throws {
        // One quad cut by a knife entering through its bottom edge and
        // leaving through the RIGHT edge: both crossed edges split, the
        // face splits between the two cut vertices into a triangle plus a
        // PENTAGON — which must come out triangulated.
        let quad = try singleQuad()
        let counts = try quad.surfaceCut(
            from: SIMD3(0.65, -0.2, 0), to: SIMD3(1.1, 0.7, 0),
            viewDirection: SIMD3(0, 0, -1)
        )
        #expect(counts.splitEdges == 2)
        #expect(counts.splitFaces == 1)
        let stats = try quad.stats()
        #expect(stats.triangles == 4)  // corner tri + triangulated pentagon
        #expect(stats.quads == 0)
        // Opt-out keeps the pentagon.
        let keeper = try singleQuad()
        _ = try keeper.surfaceCut(
            from: SIMD3(0.65, -0.2, 0), to: SIMD3(1.1, 0.7, 0),
            viewDirection: SIMD3(0, 0, -1), triangulatingNGons: false
        )
        let keptStats = try keeper.stats()
        #expect(keptStats.triangles == 1)
        #expect(keptStats.quads == 0)
        #expect(keeper.faceCount == 2)  // triangle + pentagon
    }

    @Test("surfaceCut snaps new cut vertices onto the Target")
    func surfaceCutSnapsCutVertices() throws {
        let grid = try grid32()
        _ = try grid.surfaceCut(
            from: SIMD3(-0.25, -0.35, 0), to: SIMD3(-0.25, 0.35, 0),
            viewDirection: SIMD3(0, 0, -1), snapping: try planeSnapper()
        )
        // The three new cut vertices (ids 12-14) sit on the z=0.25 plane.
        for vertex in UInt32(12)...14 {
            #expect(abs(try #require(grid.vertexPosition(vertex)).z - 0.25) < 1e-5)
        }
    }

    @Test("surfaceCut rejects degenerate segments; empty cuts are OK no-ops")
    func surfaceCutDegenerateAndEmpty() throws {
        let grid = try grid32()
        let before = try grid.payloadData()
        #expect(throws: CyberKitError.self) {
            try grid.surfaceCut(
                from: SIMD3(0, 0, 0), to: SIMD3(0, 0, 0),
                viewDirection: SIMD3(0, 0, -1)
            )
        }
        // Knife entirely off the mesh: OK with zero counts, mesh unchanged.
        let counts = try grid.surfaceCut(
            from: SIMD3(5, -1, 0), to: SIMD3(5, 1, 0), viewDirection: SIMD3(0, 0, -1)
        )
        #expect(counts.splitEdges == 0)
        #expect(counts.splitFaces == 0)
        #expect(try grid.payloadData() == before)
    }
}

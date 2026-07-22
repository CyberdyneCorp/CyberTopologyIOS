import CyberKit
import CyberKitTesting
import Foundation
import Testing
import simd

/// Task 4.2 engine patches 0018/0019: the camera-as-manipulator placement
/// operations exercised through the CyberKit facade against real engine
/// meshes — boundary-chain walks, patch cloning (shared vertices cloned
/// once, flip winding), welded boundary-ring extrusion with winding
/// correction and outer-chain stacking, the stroke-following draw strip,
/// and the vertex transform with its Target re-snap report. Deterministic
/// results are golden-filed (spec: quality-assurance / "Determinism and
/// golden-file regression tests").
@Suite("Placement mesh ops (engine)")
struct PlacementOpsTests {
    // MARK: - Fixtures

    private func mesh(fromOBJ text: String) throws -> Mesh {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("placement-ops-\(UUID().uuidString).obj")
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

    /// The committed 3x2 quad grid strip (ids row-major 0-11).
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

    private func translation(_ offset: SIMD3<Float>) -> MeshTransform {
        var transform = MeshTransform.identity
        transform.translation = offset
        return transform
    }

    // MARK: - boundaryChain (patch 0018)

    @Test("boundaryChain walks the full closed rim of an open shell")
    func boundaryChainClosesAroundGrid() throws {
        let grid = try grid32()
        // Bottom-left horizontal boundary edge (v0-v1).
        let seed = try edge(of: grid, near: SIMD3(-0.25, -0.25, 0))
        let chain = try #require(grid.boundaryChain(through: seed))
        #expect(chain.closed)
        // The 3x2 grid's rim: 10 of the 12 vertices (the 2 interior ones
        // are off the boundary), each exactly once.
        #expect(chain.vertices.count == 10)
        #expect(Set(chain.vertices).count == 10)
        #expect(!chain.vertices.contains(5))
        #expect(!chain.vertices.contains(6))
    }

    @Test("boundaryChain stops at a non-manifold pinch (open chain)")
    func boundaryChainStopsAtPinch() throws {
        // Bowtie: two triangles sharing only vertex 2 — four boundary
        // edges meet there, so the walk must stop instead of branching.
        let bowtie = try mesh(fromOBJ: """
        v 0 0 0
        v 1 0 0
        v 1.5 0.5 0
        v 2 0 0
        v 3 0 0
        f 1 2 3
        f 3 4 5
        """)
        let seed = try edge(of: bowtie, near: SIMD3(0.5, 0, 0))  // v0-v1
        let chain = try #require(bowtie.boundaryChain(through: seed))
        #expect(!chain.closed)
        // One triangle's rim, ending at the pinch vertex on both sides.
        #expect(Set(chain.vertices) == Set([0, 1, 2]))
    }

    @Test("boundaryChain rejects interior and dead edges")
    func boundaryChainRejectsNonBoundary() throws {
        let grid = try grid32()
        let interior = try edge(of: grid, near: SIMD3(-0.125, -0.125, 0))
        #expect(grid.boundaryChain(through: interior) == nil)
        #expect(grid.boundaryChain(through: 4_000_000) == nil)
    }

    // MARK: - patchClone (patch 0019)

    @Test("patchClone duplicates faces with shared vertices cloned once, golden-filed")
    func patchCloneSharesCloneVertices() throws {
        let grid = try grid32()
        // The two bottom-row quads (faces 0, 1) share an edge: the clone
        // must add 6 vertices, not 8.
        let cloned = try grid.patchClone(
            faces: [0, 1], transform: translation(SIMD3(0, 1, 0))
        )
        #expect(cloned.count == 2)
        #expect(grid.faceCount == 8)
        #expect(grid.vertexCount == 18)
        // Clone landed at the offset.
        #expect(grid.nearestVertex(to: SIMD3(-0.375, 0.75, 0), maxDistance: 1e-3) != nil)
        let golden = goldensDirectory
            .appendingPathComponent("patch_clone_grid32.payload.golden")
        try GoldenFile.compare(try grid.payloadData(), golden: golden)
    }

    @Test("patchClone snaps cloned vertices onto the Target")
    func patchCloneSnapsToTarget() throws {
        let quad = try singleQuad()
        try quad.patchClone(
            faces: [0], transform: translation(SIMD3(2, 0, 3)),
            snapping: try planeSnapper()
        )
        for vertex in UInt32(4)...7 {
            #expect(abs(try #require(quad.vertexPosition(vertex)).z - 0.25) < 1e-5)
        }
    }

    @Test("patchClone flip reverses the cloned winding")
    func patchCloneFlipReversesWinding() throws {
        let quad = try singleQuad()
        try quad.patchClone(
            faces: [0], transform: translation(SIMD3(3, 0, 0)), flipped: true
        )
        // Per-vertex normals: the original quad's vertices face +z, the
        // flipped clone's face -z.
        let normals = quad.normals()
        try #require(normals.count == 8 * 3)
        #expect(normals[2] > 0.9)  // v0 (original)
        #expect(normals[4 * 3 + 2] < -0.9)  // v4 (first cloned vertex)
    }

    @Test("patchClone rejects empty, dead, and repeated faces untouched")
    func patchCloneRejectsInvalidFaces() throws {
        let quad = try singleQuad()
        let before = try quad.payloadData()
        #expect(throws: CyberKitError.self) {
            try quad.patchClone(faces: [], transform: .identity)
        }
        #expect(throws: CyberKitError.self) {
            try quad.patchClone(faces: [99], transform: .identity)
        }
        #expect(throws: CyberKitError.self) {
            try quad.patchClone(faces: [0, 0], transform: .identity)
        }
        #expect(try quad.payloadData() == before)
    }

    // MARK: - extendBoundary (patch 0019)

    @Test("extendBoundary extrudes a welded, winding-coherent ring, golden-filed")
    func extendBoundaryExtrudesWeldedRing() throws {
        let quad = try singleQuad()
        // Bottom edge v0-v1, extruded one ring downward.
        let extension0 = try quad.extendBoundary(
            chain: [0, 1], closed: false, offset: SIMD3(0, -1, 0)
        )
        #expect(extension0.newFaces == 1)
        #expect(quad.faceCount == 2)
        #expect(quad.vertexCount == 6)
        #expect(extension0.outerChain.count == 2)
        // Welded: the chain edge now borders both faces.
        let shared = try edge(of: quad, near: SIMD3(0.5, 0, 0))
        #expect(quad.edgeFaces(of: shared).count == 2)
        // Winding-coherent: every vertex normal still faces +z.
        let normals = quad.normals()
        for base in stride(from: 0, to: normals.count, by: 3) {
            #expect(normals[base + 2] > 0.9)
        }
        let golden = goldensDirectory
            .appendingPathComponent("extend_boundary_ring.payload.golden")
        try GoldenFile.compare(try quad.payloadData(), golden: golden)
    }

    @Test("extendBoundary wraps closed chains and snaps onto the Target")
    func extendBoundaryClosedChainWraps() throws {
        let grid = try grid32()
        let seed = try edge(of: grid, near: SIMD3(-0.25, -0.25, 0))
        let chain = try #require(grid.boundaryChain(through: seed))
        #expect(chain.closed)
        let extended = try grid.extendBoundary(
            chain: chain.vertices, closed: true, offset: SIMD3(0, 0, 0.5),
            snapping: try planeSnapper()
        )
        // One quad per rim edge, wrap included.
        #expect(extended.newFaces == 10)
        #expect(grid.vertexCount == 22)
        // New ring snapped onto the plane target.
        for vertex in extended.outerChain {
            #expect(abs(try #require(grid.vertexPosition(vertex)).z - 0.25) < 1e-5)
        }
    }

    @Test("extendBoundary stacks rings through the reported outer chain")
    func extendBoundaryStacksRings() throws {
        let quad = try singleQuad()
        let first = try quad.extendBoundary(
            chain: [0, 1], closed: false, offset: SIMD3(0, -1, 0)
        )
        let second = try quad.extendBoundary(
            chain: first.outerChain, closed: false, offset: SIMD3(0.5, -0.5, 0)
        )
        #expect(quad.faceCount == 3)
        #expect(quad.vertexCount == 8)
        #expect(second.outerChain.count == 2)
        // The second ring followed its own offset from the first ring.
        let corner = try #require(quad.vertexPosition(second.outerChain[0]))
        #expect(simd_distance(corner, SIMD3(0.5, -1.5, 0)) < 1e-5)
    }

    @Test("extendBoundary rejects invalid chains and zero offsets untouched")
    func extendBoundaryRejectsInvalidChains() throws {
        let grid = try grid32()
        let before = try grid.payloadData()
        #expect(throws: CyberKitError.self) {
            try grid.extendBoundary(chain: [0], closed: false, offset: SIMD3(0, -1, 0))
        }
        #expect(throws: CyberKitError.self) {
            try grid.extendBoundary(
                chain: [0, 400], closed: false, offset: SIMD3(0, -1, 0)
            )
        }
        #expect(throws: CyberKitError.self) {
            try grid.extendBoundary(
                chain: [0, 1, 0], closed: false, offset: SIMD3(0, -1, 0)
            )
        }
        #expect(throws: CyberKitError.self) {
            // 0 and 5 are diagonal — no edge joins them.
            try grid.extendBoundary(
                chain: [0, 5], closed: false, offset: SIMD3(0, -1, 0)
            )
        }
        #expect(throws: CyberKitError.self) {
            // Closed needs a live wrap edge (0-1-2 is a straight run).
            try grid.extendBoundary(chain: [0, 1, 2], closed: true, offset: SIMD3(0, -1, 0))
        }
        #expect(throws: CyberKitError.self) {
            try grid.extendBoundary(chain: [0, 1], closed: false, offset: .zero)
        }
        #expect(try grid.payloadData() == before)
    }

    // MARK: - extendBoundaryFan (patch 0019)

    @Test("extendBoundaryFan closes an open chain onto a snapped apex")
    func extendBoundaryFanClosesChain() throws {
        let quad = try singleQuad()
        let fan = try quad.extendBoundaryFan(
            chain: [0, 1], closed: false, apexOffset: SIMD3(0, -1, 0),
            snapping: try planeSnapper()
        )
        #expect(fan.newFaces == 1)
        #expect(quad.faceCount == 2)
        #expect(try quad.stats().triangles == 1)
        let apex = try #require(quad.vertexPosition(fan.apex))
        // Chain centroid (0.5, 0, 0) + offset, snapped onto z = 0.25.
        #expect(abs(apex.x - 0.5) < 1e-5)
        #expect(abs(apex.y + 1) < 1e-5)
        #expect(abs(apex.z - 0.25) < 1e-5)
    }

    @Test("extendBoundaryFan fans a closed rim with one triangle per edge")
    func extendBoundaryFanClosedRim() throws {
        let grid = try grid32()
        let seed = try edge(of: grid, near: SIMD3(-0.25, -0.25, 0))
        let chain = try #require(grid.boundaryChain(through: seed))
        let fan = try grid.extendBoundaryFan(
            chain: chain.vertices, closed: true, apexOffset: SIMD3(0, 0, 1)
        )
        #expect(fan.newFaces == 10)
        #expect(try grid.stats().triangles == 10)
        #expect(grid.vertexCount == 13)
    }

    // MARK: - drawStrip (patch 0019)

    @Test("drawStrip welds onto the start edge and preserves the width")
    func drawStripWeldsAndKeepsWidth() throws {
        let quad = try singleQuad()
        // Straight two-station path below the bottom edge v0-v1.
        let faces = try quad.drawStrip(
            path: [SIMD3(0.5, -1, 0), SIMD3(0.5, -2, 0)],
            width: 1, viewDirection: SIMD3(0, 0, -1), weldingOnto: (0, 1)
        )
        #expect(faces == 2)
        #expect(quad.faceCount == 3)
        #expect(quad.vertexCount == 8)
        #expect(try quad.stats().quads == 3)
        // Welded: the start edge borders both faces now.
        let start = try edge(of: quad, near: SIMD3(0.5, 0, 0))
        #expect(quad.edgeFaces(of: start).count == 2)
        // Rail pairs span the width around each station.
        #expect(quad.nearestVertex(to: SIMD3(0, -1, 0), maxDistance: 1e-4) != nil)
        #expect(quad.nearestVertex(to: SIMD3(1, -1, 0), maxDistance: 1e-4) != nil)
        // Winding-coherent with the source quad.
        let normals = quad.normals()
        for base in stride(from: 0, to: normals.count, by: 3) {
            #expect(normals[base + 2] > 0.9)
        }
    }

    @Test("drawStrip follows curved paths without flipping rails")
    func drawStripFollowsCurvedPath() throws {
        let quad = try singleQuad()
        // An L-turn: down, then off to the right.
        let faces = try quad.drawStrip(
            path: [
                SIMD3(0.5, -1, 0), SIMD3(0.7, -1.9, 0), SIMD3(1.6, -2.4, 0),
                SIMD3(2.6, -2.6, 0),
            ],
            width: 1, viewDirection: SIMD3(0, 0, -1), weldingOnto: (0, 1)
        )
        // Every station bridged: rails never flipped into degenerate quads.
        #expect(faces == 4)
        #expect(try quad.stats().quads == 5)
    }

    @Test("drawStrip rejects invalid input untouched")
    func drawStripRejectsInvalidInput() throws {
        let grid = try grid32()
        let before = try grid.payloadData()
        #expect(throws: CyberKitError.self) {
            try grid.drawStrip(
                path: [], width: 1, viewDirection: SIMD3(0, 0, -1), weldingOnto: (0, 1)
            )
        }
        #expect(throws: CyberKitError.self) {
            try grid.drawStrip(
                path: [SIMD3(0, -1, 0)], width: 0, viewDirection: SIMD3(0, 0, -1),
                weldingOnto: (0, 1)
            )
        }
        #expect(throws: CyberKitError.self) {
            // 1-6 is an INTERIOR edge of the grid.
            try grid.drawStrip(
                path: [SIMD3(0, -1, 0)], width: 1, viewDirection: SIMD3(0, 0, -1),
                weldingOnto: (1, 6)
            )
        }
        #expect(throws: CyberKitError.self) {
            try grid.drawStrip(
                path: [SIMD3(0, -1, 0)], width: 1, viewDirection: .zero,
                weldingOnto: (0, 1)
            )
        }
        #expect(try grid.payloadData() == before)
    }

    // MARK: - transformVertices (patch 0019)

    @Test("transformVertices applies the affine and reports the re-snap")
    func transformVerticesAppliesAndReports() throws {
        let quad = try singleQuad()
        // Lift all four vertices to z = 1; the plane target at z = 0.25
        // re-snaps every one of them by 0.75.
        let report = try quad.transformVertices(
            [0, 1, 2, 3], transform: translation(SIMD3(0, 0, 1)),
            reprojecting: try planeSnapper(), resnapEpsilon: 1e-4
        )
        #expect(report.resnapped == 4)
        #expect(abs(report.maxDistance - 0.75) < 1e-4)
        for vertex in UInt32(0)...3 {
            #expect(abs(try #require(quad.vertexPosition(vertex)).z - 0.25) < 1e-5)
        }
    }

    @Test("transformVertices without a snapper moves exactly and reports zero")
    func transformVerticesWithoutSnapper() throws {
        let quad = try singleQuad()
        let report = try quad.transformVertices(
            [0, 2], transform: translation(SIMD3(0.5, 0, 2))
        )
        #expect(report.resnapped == 0)
        #expect(report.maxDistance == 0)
        #expect(try #require(quad.vertexPosition(0)) == SIMD3(0.5, 0, 2))
        #expect(try #require(quad.vertexPosition(1)) == SIMD3(1, 0, 0))  // untouched
    }

    @Test("transformVertices rejects empty, dead, and repeated ids untouched")
    func transformVerticesRejectsInvalidIds() throws {
        let quad = try singleQuad()
        let before = try quad.payloadData()
        #expect(throws: CyberKitError.self) {
            try quad.transformVertices([], transform: .identity)
        }
        #expect(throws: CyberKitError.self) {
            try quad.transformVertices([99], transform: .identity)
        }
        #expect(throws: CyberKitError.self) {
            try quad.transformVertices([0, 0], transform: .identity)
        }
        #expect(try quad.payloadData() == before)
    }

    // MARK: - MeshTransform (pure)

    @Test("MeshTransform round-trips a 4x4 and applies points/directions")
    func meshTransformFromMatrix() {
        // 90° about z + translation.
        let matrix = simd_float4x4(columns: (
            SIMD4(0, 1, 0, 0), SIMD4(-1, 0, 0, 0), SIMD4(0, 0, 1, 0),
            SIMD4(3, 0, 0, 1)
        ))
        let transform = MeshTransform(matrix)
        let p = transform.apply(SIMD3(1, 0, 0))
        #expect(simd_distance(p, SIMD3(3, 1, 0)) < 1e-6)
        let d = transform.applyDirection(SIMD3(1, 0, 0))
        #expect(simd_distance(d, SIMD3(0, 1, 0)) < 1e-6)
        #expect(MeshTransform.identity.apply(SIMD3(4, 5, 6)) == SIMD3(4, 5, 6))
    }
}

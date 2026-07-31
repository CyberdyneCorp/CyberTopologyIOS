import CyberKit
import CyberKitTesting
import Foundation
import Testing
import simd

/// Painted-region auto-retopology, engine side (openspec
/// add-painted-region-retopo): carving the solve domain out of the Target, and
/// merging the resulting patch into an existing cage.
///
/// Public-API + inline OBJ fixtures, so this suite runs on DEVICE too.
@Suite("Region retopo ops")
struct RegionRetopoOpsTests {
    private func mesh(fromOBJ text: String) throws -> Mesh {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("region-\(UUID().uuidString).obj")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Mesh.loadOBJ(at: url)
    }

    /// A `cells` x `cells` quad grid on z = 0, unit cells.
    private func grid(cells: Int) throws -> Mesh {
        var lines: [String] = []
        let side = cells + 1
        for y in 0..<side {
            for x in 0..<side { lines.append("v \(x) \(y) 0") }
        }
        for y in 0..<cells {
            for x in 0..<cells {
                let a = y * side + x + 1
                lines.append("f \(a) \(a + 1) \(a + side + 1) \(a + side)")
            }
        }
        return try mesh(fromOBJ: lines.joined(separator: "\n"))
    }

    // MARK: - Carving the solve domain

    @Test("the carve keeps exactly the region's faces")
    func carveKeepsTheRegion() throws {
        let target = try grid(cells: 4)
        let all = target.liveFaceIDs().sorted()
        let painted = Array(all.prefix(5))

        let carved = try EngineRemeshSolver.carved(target, to: .faces(painted)).mesh

        #expect(carved.faceCount == 5)
        #expect(Set(carved.liveFaceIDs()) == Set(painted), "ids are preserved by the duplicate")
        // …and the Target itself is untouched: it is only ever the surface.
        #expect(target.faceCount == 16)
    }

    @Test("a whole-mesh region hands back the source itself")
    func wholeMeshIsNotCarved() throws {
        let target = try grid(cells: 2)
        let same = try EngineRemeshSolver.carved(target, to: .wholeMesh).mesh
        #expect(same.faceCount == target.faceCount)
    }

    /// Both refusals exist to surface a selection bug rather than silently do
    /// something else.
    @Test("an empty region, and one naming every face, are refused")
    func degenerateRegionsAreRefused() throws {
        let target = try grid(cells: 2)
        #expect(throws: (any Error).self) {
            _ = try EngineRemeshSolver.carved(target, to: .faces([]))
        }
        #expect(throws: (any Error).self) {
            _ = try EngineRemeshSolver.carved(
                target, to: .faces(target.liveFaceIDs().sorted())
            )
        }
        #expect(target.faceCount == 4, "a refusal leaves the Target alone")
    }

    /// A Target can be reloaded under a stale selection; that must not fail a
    /// solve, only narrow it.
    @Test("dead ids in the region are ignored")
    func deadIDsAreIgnored() throws {
        let target = try grid(cells: 4)
        let painted = target.liveFaceIDs().sorted().prefix(3)
        let stale = UInt32(target.vertexCapacity + 500)  // certainly not a live face id

        let carved = try EngineRemeshSolver.carved(target, to: .faces(Array(painted) + [stale])).mesh

        #expect(carved.faceCount == 3)
    }

    /// Does a carved region actually SOLVE? The carve is only useful if the
    /// remesher accepts what it produces. Time-limited because a solver that
    /// spins would otherwise hang the whole suite rather than fail it.
    @Test("a carved region solves", .timeLimit(.minutes(1)))
    func carvedRegionSolves() async throws {
        let target = try grid(cells: 6)
        let painted = Array(target.liveFaceIDs().sorted().prefix(12))

        // A REALISTIC budget: `SolverParameters()` is the engine's raw 50 000-quad
        // default, and asking a 12-face patch for 50 000 quads does not finish
        // inside a minute (measured — it is what made this test hang before the
        // share-scaling below existed).
        let ghost = try EngineRemeshSolver().solve(
            source: target, region: .faces(painted), constraints: WeaveConstraints(),
            params: .medium, onProgress: nil, isCancelled: { false }
        )

        #expect(ghost != nil)
        #expect(target.faceCount == 36, "the Target is never modified by a solve")
        // The budget followed the painted share (12 of 36 faces), so the patch is
        // a patch — not a whole model's worth of quads inside a third of one.
        let quads = try #require(ghost).mesh.faceCount
        #expect(quads > 0 && quads < 1500, "region cage has \(quads) faces")
    }

    /// QUALITY: a region solve returns QUADS, not a triangle fan.
    ///
    /// Reported from device as "why is the auto-retopo quality that bad?" with
    /// slivers over a painted ear. Measured on this carve at the shipped settings:
    /// 242 of 441 faces were triangles and 35 were n-gons, because the engine
    /// defaults to quad-DOMINANT and the app never overrode it. Every solver preset
    /// now asks for pure quads.
    @Test("a region solve returns pure quads", .timeLimit(.minutes(2)))
    func regionSolveReturnsPureQuads() async throws {
        let target = try Mesh.loadOBJ(at: MeshFixtureCorpus.stanfordBunnyURL())
        let all = target.liveFaceIDs().sorted()
        let painted = Array(all.prefix(all.count / 12))

        let ghost = try #require(
            try EngineRemeshSolver().solve(
                source: target, region: .faces(painted), constraints: WeaveConstraints(),
                params: .medium, onProgress: nil, isCancelled: { false }
            )
        )

        let stats = try ghost.mesh.stats()
        #expect(stats.quads > 0)
        #expect(
            stats.triangles == 0 && stats.other == 0,
            "cage has \(stats.triangles) triangles and \(stats.other) n-gons"
        )
    }

    // MARK: - Merging the patch

    @Test("append adds the patch's faces to the receiving cage")
    func appendAddsFaces() throws {
        let cage = try grid(cells: 2)  // 4 faces, 9 vertices
        let patch = try grid(cells: 1)  // 1 face, 4 vertices
        let facesBefore = cage.faceCount
        let verticesBefore = cage.vertexCount

        let report = try cage.append(patch)

        #expect(report.facesAdded == 1)
        #expect(report.facesSkipped == 0)
        #expect(cage.faceCount == facesBefore + 1)
        // Nothing is welded: the patch brings its own 4 vertices even though they
        // sit exactly on the cage's.
        #expect(cage.vertexCount == verticesBefore + 4)
    }

    @Test("the patch keeps its own shared edges")
    func appendPreservesSharing() throws {
        let cage = try grid(cells: 1)
        // A 2x2 patch: 4 faces sharing an interior vertex and 4 interior edges.
        let patch = try grid(cells: 2)
        let verticesBefore = cage.vertexCount

        let report = try cage.append(patch)

        #expect(report.facesAdded == 4)
        // 9 vertices, NOT 16: a face reusing a vertex an earlier face created
        // must share it, or the patch arrives as loose quads.
        #expect(cage.vertexCount == verticesBefore + 9)
        #expect(report.verticesAdded == 9)
    }

    @Test("positions are copied exactly")
    func appendCopiesPositionsExactly() throws {
        let cage = try grid(cells: 1)
        var lines: [String] = []
        for point in [
            SIMD3<Float>(10.25, -3.5, 0.125), SIMD3(11.25, -3.5, 0.125),
            SIMD3(11.25, -2.5, 0.125), SIMD3(10.25, -2.5, 0.125),
        ] {
            lines.append("v \(point.x) \(point.y) \(point.z)")
        }
        lines.append("f 1 2 3 4")
        let patch = try mesh(fromOBJ: lines.joined(separator: "\n"))

        try cage.append(patch)

        for expected in [
            SIMD3<Float>(10.25, -3.5, 0.125), SIMD3(11.25, -3.5, 0.125),
            SIMD3(11.25, -2.5, 0.125), SIMD3(10.25, -2.5, 0.125),
        ] {
            #expect(
                cage.nearestVertex(to: expected, maxDistance: 1e-6) != nil,
                "\(expected) did not arrive intact"
            )
        }
    }

    @Test("appending an empty mesh is a no-op")
    func appendingNothingChangesNothing() throws {
        let cage = try grid(cells: 2)
        let before = cage.faceCount
        let report = try cage.append(try Mesh())
        #expect(report.facesAdded == 0)
        #expect(cage.faceCount == before)
    }
}

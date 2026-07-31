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

        // `dilating: 0` — this asserts which faces the carve SELECTS; the shipped
        // default grows the region by two rings to smooth its border (see
        // `regionDilationRings`), which is covered separately.
        let carved = try EngineRemeshSolver.carved(target, to: .faces(painted), dilating: 0).mesh

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

        let carved = try EngineRemeshSolver.carved(
            target, to: .faces(Array(painted) + [stale]), dilating: 0
        ).mesh

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

    /// QUALITY, measured: a painted patch comes back as an EVEN, OPEN grid.
    ///
    /// Reported from device with a screenshot of a patch whose quads varied wildly
    /// over a near-planar surface. Two engine defaults were wrong for a region:
    /// `adaptivity = 1` (fully curvature-adaptive, right for a whole model) gave a
    /// 31.8x spread between the largest and smallest quad on a 440-face patch, and
    /// hole filling SEALED the patch — zero boundary edges, a closed bubble rather
    /// than something to merge into a cage.
    @Test("a painted patch is an even, open grid", .timeLimit(.minutes(3)))
    func regionPatchIsEvenAndOpen() async throws {
        let target = try Mesh.loadOBJ(at: MeshFixtureCorpus.stanfordBunnyURL())
        let ids = target.liveFaceIDs().sorted()
        // A compact blob, like a painted one — not "the first N ids".
        let seed = try #require(target.faceCentroid(ids[ids.count / 3]))
        let centroids = ids.compactMap { target.faceCentroid($0) }
        let lo = centroids.reduce(SIMD3<Float>(repeating: .greatestFiniteMagnitude)) { simd_min($0, $1) }
        let hi = centroids.reduce(SIMD3<Float>(repeating: -.greatestFiniteMagnitude)) { simd_max($0, $1) }
        let radius = simd_length(hi - lo) * 0.12
        let painted = ids.filter { face in
            (target.faceCentroid(face)).map { simd_distance($0, seed) < radius } ?? false
        }
        #expect(painted.count > 100, "the fixture patch is too small to judge")

        let ghost = try #require(
            try EngineRemeshSolver().solve(
                source: target, region: .faces(painted), constraints: WeaveConstraints(),
                params: .targetingQuads(500), onProgress: nil, isCancelled: { false }
            )
        )
        let patch = ghost.mesh

        // OPEN: the region's boundary must survive, or the patch is a sealed bubble.
        var boundary = 0
        for id in UInt32(0)..<UInt32(patch.edgeCapacity) where patch.isBoundaryEdge(id) == true {
            boundary += 1
        }
        #expect(boundary > 0, "the patch came back sealed — hole filling closed the region")

        // EVEN: quad areas within an order of magnitude, p90 over p10.
        var areas: [Float] = []
        for face in patch.liveFaceIDs() {
            let ring = patch.faceVertices(face).compactMap { patch.vertexPosition($0) }
            guard ring.count >= 3 else { continue }
            var area: Float = 0
            for index in 1..<(ring.count - 1) {
                area += simd_length(
                    simd_cross(ring[index] - ring[0], ring[index + 1] - ring[0])
                ) / 2
            }
            areas.append(area)
        }
        areas.sort()
        let spread = areas[areas.count * 9 / 10] / max(areas[areas.count / 10], 1e-9)
        #expect(spread < 6, "quad areas spread \(spread)x — the cage is uneven")
        // The requested count reaches the PATCH: 500 asked, a patch-sized cage back.
        #expect(patch.faceCount > 300 && patch.faceCount < 900, "patch has \(patch.faceCount) f")

    }

    /// The same painted region must solve IDENTICALLY twice.
    ///
    /// It did not: three solves of one region returned 649, 631 and 603 faces, one
    /// of them containing a 434 996:1 degenerate face. The remesher is deterministic
    /// — the CARVE was not. `deleteFaces` is order-sensitive (it compacts ids and
    /// prunes isolated vertices as it goes) and was being handed a `Set`'s arbitrary
    /// iteration order, so the mesh reaching the remesher differed run to run.
    ///
    /// This is also why every quality number measured against this path before the
    /// fix was a single sample of a distribution rather than a measurement.
    @Test("the same painted region solves identically twice", .timeLimit(.minutes(3)))
    func regionSolveIsDeterministic() async throws {
        let target = try Mesh.loadOBJ(at: MeshFixtureCorpus.stanfordBunnyURL())
        // Dense enough to exercise a real carve (device Targets are far denser).
        _ = try target.subdivide()
        let ids = target.liveFaceIDs().sorted()
        let seed = try #require(target.faceCentroid(ids[ids.count / 3]))
        let centroids = ids.compactMap { target.faceCentroid($0) }
        let lo = centroids.reduce(SIMD3<Float>(repeating: .greatestFiniteMagnitude)) { simd_min($0, $1) }
        let hi = centroids.reduce(SIMD3<Float>(repeating: -.greatestFiniteMagnitude)) { simd_max($0, $1) }
        let radius = simd_length(hi - lo) * 0.12
        let painted = ids.filter { face in
            (target.faceCentroid(face)).map { simd_distance($0, seed) < radius } ?? false
        }

        func solveOnce() throws -> Data {
            let ghost = try #require(
                try EngineRemeshSolver().solve(
                    source: target, region: .faces(painted), constraints: WeaveConstraints(),
                    params: .targetingQuads(500), onProgress: nil, isCancelled: { false }
                )
            )
            return try ghost.mesh.payloadData()
        }

        let first = try solveOnce()
        let second = try solveOnce()
        #expect(first == second)
    }

    /// The carve itself, which is where the instability lived.
    @Test("carving the same region twice gives the same mesh")
    func carveIsDeterministic() throws {
        let target = try Mesh.loadOBJ(at: MeshFixtureCorpus.stanfordBunnyURL())
        let painted = Array(target.liveFaceIDs().sorted().prefix(300))
        let first = try EngineRemeshSolver.carved(target, to: .faces(painted))
        let second = try EngineRemeshSolver.carved(target, to: .faces(painted))
        let a = try first.mesh.payloadData()
        let b = try second.mesh.payloadData()
        #expect(a == b)
    }

    /// BORDER: growing the region before carving gives the patch a smoother
    /// perimeter than the raw painted set does.
    ///
    /// Asserted RELATIVELY — dilated versus raw on the same patch — because the
    /// absolute numbers depend on the patch and the Target's density, while the
    /// improvement holds across every patch measured (see `regionDilationRings`).
    @Test("a grown region gives a smoother patch border", .timeLimit(.minutes(3)))
    func regionDilationSmoothsTheBorder() async throws {
        let target = try Mesh.loadOBJ(at: MeshFixtureCorpus.stanfordBunnyURL())
        _ = try target.subdivide()
        let ids = target.liveFaceIDs().sorted()
        let seed = try #require(target.faceCentroid(ids[ids.count / 3]))
        let centroids = ids.compactMap { target.faceCentroid($0) }
        let lo = centroids.reduce(SIMD3<Float>(repeating: .greatestFiniteMagnitude)) { simd_min($0, $1) }
        let hi = centroids.reduce(SIMD3<Float>(repeating: -.greatestFiniteMagnitude)) { simd_max($0, $1) }
        let radius = simd_length(hi - lo) * 0.12
        let painted = ids.filter { face in
            (target.faceCentroid(face)).map { simd_distance($0, seed) < radius } ?? false
        }

        func patch(dilating rings: Int) throws -> (boundary: Int, worst: Float) {
            let carve = try EngineRemeshSolver.carved(
                target, to: .faces(painted), dilating: rings
            )
            var params = EngineRemeshSolver.regionParameters(
                SolverParameters.targetingQuads(500).remesh, carve: carve
            )
            params.pureQuads = true
            let out = try #require(try carve.mesh.remeshed(parameters: params))
            var boundary = 0
            for id in UInt32(0)..<UInt32(out.edgeCapacity) where out.isBoundaryEdge(id) == true {
                boundary += 1
            }
            var worst: Float = 0
            for face in out.liveFaceIDs() {
                let ring = out.faceVertices(face).compactMap { out.vertexPosition($0) }
                guard ring.count >= 3 else { continue }
                var short = Float.greatestFiniteMagnitude, long: Float = 0
                for index in 0..<ring.count {
                    let d = simd_distance(ring[index], ring[(index + 1) % ring.count])
                    short = min(short, d)
                    long = max(long, d)
                }
                if short > 1e-9 { worst = max(worst, long / short) }
            }
            return (boundary, worst)
        }

        let raw = try patch(dilating: 0)
        let grown = try patch(dilating: EngineRemeshSolver.regionDilationRings)

        #expect(
            grown.boundary < raw.boundary,
            "perimeter did not get smoother: \(grown.boundary) vs \(raw.boundary) edges"
        )
        #expect(
            grown.worst < raw.worst,
            "worst face got worse: \(grown.worst):1 vs \(raw.worst):1"
        )
        // And no degenerate faces, which a closing produced (277 294:1).
        #expect(grown.worst < 100, "degenerate face at \(grown.worst):1")
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

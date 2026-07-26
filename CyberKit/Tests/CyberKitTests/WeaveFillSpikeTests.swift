import CyberKit
import Foundation
import Testing
import simd

/// FEASIBILITY SPIKE — task 0 of `add-weave-region-selection`.
///
/// The question the change rests on: can the solve domain be GROWN from the cage's
/// open boundary (`extendBoundary`, already Target-snapped) instead of CARVED out of
/// the Target (which would need a curved surface cut that does not exist)?
///
/// Reports four numbers. **(d) is the falsifier.** The seed rows are snapped to the
/// Target, but the region solve then reprojects onto a `ReferenceSurface` built from
/// cage+seed, NOT from the Target. If a coarse seed drifts far from the Target, then
/// 5.4b (an external reference surface) stops being a quality improvement and becomes
/// a prerequisite for this whole change.
@Suite("Weave fill — feasibility spike")
struct WeaveFillSpikeTests {

    /// The dome every fixture lives on. Target and cage sample the SAME function, so
    /// any deviation measured at the end is caused by the solve, not by the setup.
    private static func domeHeight(_ x: Float, _ y: Float) -> Float {
        0.5 * max(0, 1.0 - (x * x + y * y) / 2.0)
    }

    private func mesh(fromOBJ text: String) throws -> Mesh {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fill-\(UUID().uuidString).obj")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Mesh.loadOBJ(at: url)
    }

    /// High-poly TRIANGLE Target over [-1,1]^2 — the surface, never modified.
    private func domedTarget(n: Int = 24) throws -> Mesh {
        var obj = ""
        for i in 0...n {
            for j in 0...n {
                let x = 2 * Float(i) / Float(n) - 1, y = 2 * Float(j) / Float(n) - 1
                obj += "v \(x) \(y) \(Self.domeHeight(x, y))\n"
            }
        }
        let v = { (a: Int, b: Int) in a * (n + 1) + b + 1 }
        for i in 0..<n {
            for j in 0..<n {
                obj += "f \(v(i, j)) \(v(i + 1, j)) \(v(i + 1, j + 1))\n"
                obj += "f \(v(i, j)) \(v(i + 1, j + 1)) \(v(i, j + 1))\n"
            }
        }
        return try mesh(fromOBJ: obj)
    }

    /// A coarse QUAD cage covering only the lower band of the dome, leaving the rest
    /// bare — the "artist hand-drew the 10%" state Weave is meant to continue from.
    /// 4 columns x 2 rows over x in [-0.8, 0.8], y in [-0.8, -0.2].
    private func partialCage() throws -> Mesh {
        var obj = ""
        let cols = 4, rows = 2
        for i in 0...cols {
            for j in 0...rows {
                let x = -0.8 + 1.6 * Float(i) / Float(cols)
                let y = -0.8 + 0.6 * Float(j) / Float(rows)
                obj += "v \(x) \(y) \(Self.domeHeight(x, y))\n"
            }
        }
        let v = { (a: Int, b: Int) in a * (rows + 1) + b + 1 }
        for i in 0..<cols {
            for j in 0..<rows {
                obj += "f \(v(i, j)) \(v(i + 1, j)) \(v(i + 1, j + 1)) \(v(i, j + 1))\n"
            }
        }
        return try mesh(fromOBJ: obj)
    }

    /// The cage's TOP edge (y = -0.2) as an ordered open chain: the free boundary a
    /// fill grows from. Taken as the contiguous run of the boundary loop whose
    /// vertices all sit at the maximum y — the app selects such a run with a stroke.
    private func topChain(of cage: Mesh) -> [UInt32] {
        let ys = (0..<UInt32(cage.vertexCount)).compactMap { cage.vertexPosition($0)?.y }
        guard let maxY = ys.max() else { return [] }
        let onTop = (0..<UInt32(cage.vertexCount)).filter {
            guard let p = cage.vertexPosition($0) else { return false }
            return abs(p.y - maxY) < 1e-5
        }
        // Order along x so the chain is a walk, not a set.
        return onTop.sorted {
            (cage.vertexPosition($0)?.x ?? 0) < (cage.vertexPosition($1)?.x ?? 0)
        }
    }

    private func maxDeviation(_ mesh: Mesh, vertices: [UInt32], from snapper: SurfaceSnapper)
        -> Float
    {
        var worst: Float = 0
        for v in vertices {
            guard let p = mesh.vertexPosition(v), let hit = snapper.snapToSurface(p) else {
                continue
            }
            worst = max(worst, simd_length(hit.point - p))
        }
        return worst
    }

    @Test("Growing the domain from the cage boundary is viable")
    func growThenSolve() throws {
        let target = try domedTarget()
        let snapper = try SurfaceSnapper(target: target)
        let cage = try partialCage()

        let chain = topChain(of: cage)
        #expect(chain.count == 5, "the cage's free edge should be 5 vertices wide")

        // What must survive the whole operation, captured before anything runs.
        let cageFacesBefore = cage.liveFaceIDs()
        var cageRings: [UInt32: [UInt32]] = [:]
        var cagePositions: [UInt32: SIMD3<Float>] = [:]
        for f in cageFacesBefore {
            cageRings[f] = cage.faceVertices(f)
            for v in cage.faceVertices(f) { cagePositions[v] = cage.vertexPosition(v) }
        }
        let targetPayloadBefore = try target.payloadData()

        // --- GROW: two snapped quad rows off the free edge, over bare Target.
        let facesBefore = Set(cage.liveFaceIDs())
        let rowStep = SIMD3<Float>(0, 0.3, 0)  // ~one cage quad tall
        let extension_ = try cage.extendBoundary(
            chain: chain, closed: false, offset: rowStep, rings: 2, snapping: snapper
        )
        let seedFaces = cage.liveFaceIDs().filter { !facesBefore.contains($0) }
        #expect(extension_.newFaces == seedFaces.count)
        #expect(seedFaces.count == 8, "4 quads per row x 2 rows")

        let seedVertices = Set(seedFaces.flatMap { cage.faceVertices($0) })
            .subtracting(cagePositions.keys)
        let seedDeviation = maxDeviation(cage, vertices: Array(seedVertices), from: snapper)

        // --- SOLVE: rewrite exactly the seed, cage frozen.
        let budget = RegionWeaveSolver.prescribedQuadBudget(
            source: cage, regionFaces: seedFaces
        ) ?? 8
        var params = RemeshParameters()
        params.targetQuads = budget
        let solved = try #require(
            try cage.remeshedRegion(faces: seedFaces, parameters: params)
        )
        let report = try #require(solved.regionReport())

        // (a) the artist's cage is untouched, bitwise.
        var movedCageVertices = 0
        for (v, p) in cagePositions {
            guard let now = solved.vertexPosition(v),
                now.x.bitPattern == p.x.bitPattern,
                now.y.bitPattern == p.y.bitPattern,
                now.z.bitPattern == p.z.bitPattern
            else {
                movedCageVertices += 1
                continue
            }
        }
        var brokenCageFaces = 0
        for (f, ring) in cageRings where solved.faceVertices(f) != ring { brokenCageFaces += 1 }

        // (b) manifold across the seam: every interface vertex still carries faces.
        let orphanInterface = report.interfaceVertices.filter {
            (solved.vertexFaceCount($0) ?? 0) == 0
        }

        // (d) THE FALSIFIER — how far the solved band sits off the Target.
        let solvedFaces = solved.solvedFaceIDs() ?? []
        let solvedVertices = Set(solvedFaces.flatMap { solved.faceVertices($0) })
            .subtracting(cagePositions.keys)
        let solvedDeviation = maxDeviation(solved, vertices: Array(solvedVertices), from: snapper)

        // Scale-free: the dome spans 2 units, cage quads are ~0.4 across.
        let quadSize: Float = 0.4

        print("""
        [weave-fill spike]
          (a) cage vertices moved            = \(movedCageVertices) / \(cagePositions.count)
              cage face rings changed        = \(brokenCageFaces) / \(cageRings.count)
          (b) orphaned interface vertices    = \(orphanInterface.count)
          (c) irregular interface vertices   = \(report.interfaceIrregular.count) \
        / \(report.interfaceVertices.count)   seam triangles = \(report.interfaceTriangles)
          (d) seed deviation from Target     = \(seedDeviation) (\(seedDeviation / quadSize) quads)
              SOLVED deviation from Target   = \(solvedDeviation) (\(solvedDeviation / quadSize) quads)
          faces: cage \(cageFacesBefore.count), seed \(seedFaces.count), solved \(solvedFaces.count)
              prescribed budget = \(budget) quads  ->  actually produced \(solvedFaces.count)
        """)

        // (a) and (b) are the guarantee — these must hold or the approach is dead.
        #expect(movedCageVertices == 0)
        #expect(brokenCageFaces == 0)
        #expect(orphanInterface.isEmpty)
        // The Target is a reference surface, never an output.
        #expect(try target.payloadData() == targetPayloadBefore)
    }
}

/// `WeaveFillDomain` — task 1 of add-weave-region-selection. Drives it the way the
/// app will: a fill POINT, not a hand-picked chain.
@Suite("Weave fill domain")
struct WeaveFillDomainTests {
    private static func domeHeight(_ x: Float, _ y: Float) -> Float {
        0.5 * max(0, 1.0 - (x * x + y * y) / 2.0)
    }

    private func mesh(fromOBJ text: String) throws -> Mesh {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dom-\(UUID().uuidString).obj")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Mesh.loadOBJ(at: url)
    }

    private func domedTarget(n: Int = 24) throws -> Mesh {
        var obj = ""
        for i in 0...n {
            for j in 0...n {
                let x = 2 * Float(i) / Float(n) - 1, y = 2 * Float(j) / Float(n) - 1
                obj += "v \(x) \(y) \(Self.domeHeight(x, y))\n"
            }
        }
        let v = { (a: Int, b: Int) in a * (n + 1) + b + 1 }
        for i in 0..<n {
            for j in 0..<n {
                obj += "f \(v(i, j)) \(v(i + 1, j)) \(v(i + 1, j + 1))\n"
                obj += "f \(v(i, j)) \(v(i + 1, j + 1)) \(v(i, j + 1))\n"
            }
        }
        return try mesh(fromOBJ: obj)
    }

    /// Coarse quad cage over the lower band of the dome — its boundary is a CLOSED
    /// rectangle loop, which is the normal case and the reason a facing run is needed.
    private func partialCage() throws -> Mesh {
        var obj = ""
        let cols = 4, rows = 2
        for i in 0...cols {
            for j in 0...rows {
                let x = -0.8 + 1.6 * Float(i) / Float(cols)
                let y = -0.8 + 0.6 * Float(j) / Float(rows)
                obj += "v \(x) \(y) \(Self.domeHeight(x, y))\n"
            }
        }
        let v = { (a: Int, b: Int) in a * (rows + 1) + b + 1 }
        for i in 0..<cols {
            for j in 0..<rows {
                obj += "f \(v(i, j)) \(v(i + 1, j)) \(v(i + 1, j + 1)) \(v(i, j + 1))\n"
            }
        }
        return try mesh(fromOBJ: obj)
    }

    /// A closed cage — a tetrahedron. No free edge, so nothing to grow from.
    private func closedCage() throws -> Mesh {
        try mesh(fromOBJ: """
        v 0 0 0
        v 1 0 0
        v 0 1 0
        v 0 0 1
        f 1 3 2
        f 1 2 4
        f 2 3 4
        f 3 1 4
        """)
    }

    private func fillPoint() -> SIMD3<Float> { SIMD3(0, 0.6, Self.domeHeight(0, 0.6)) }

    @Test("Growing from a fill point picks the facing run of a CLOSED boundary loop")
    func facingRunFromClosedLoop() throws {
        let cage = try partialCage()
        let snapper = try SurfaceSnapper(target: try domedTarget())

        let seed = try WeaveFillDomain.grow(
            cage: cage, snapper: snapper, towards: fillPoint(), rows: 2
        )

        // The cage's boundary loop is 14 vertices; only the +y edge (5) faces the
        // fill point. Growing the whole loop would SHIFT the cage, not extend it.
        #expect(seed.chain.count == 5)
        for v in seed.chain {
            let y = try #require(cage.vertexPosition(v)).y
            #expect(abs(y - (-0.2)) < 1e-5, "the run should be the +y edge")
        }
        #expect(seed.rows == 2)
        #expect(seed.seedFaces.count == 8)  // 4 quads per row x 2
        #expect(seed.step.y > 0, "the step should point towards the fill")
    }

    @Test("The live cage is never touched — the seed lives on a copy")
    func seedNeverTouchesTheCage() throws {
        let cage = try partialCage()
        let snapper = try SurfaceSnapper(target: try domedTarget())
        let facesBefore = cage.liveFaceIDs()
        let ringsBefore = facesBefore.map { cage.faceVertices($0) }

        let seed = try WeaveFillDomain.grow(
            cage: cage, snapper: snapper, towards: fillPoint(), rows: 3
        )

        // This is what makes a discarded proposal leave nothing behind.
        #expect(cage.liveFaceIDs() == facesBefore)
        #expect(facesBefore.map { cage.faceVertices($0) } == ringsBefore)
        // …and the copy is ID-PRESERVING, so the chain means the same thing in both.
        for v in seed.chain {
            #expect(seed.mesh.vertexPosition(v) == cage.vertexPosition(v))
        }
        for f in facesBefore {
            #expect(seed.mesh.faceVertices(f) == cage.faceVertices(f))
        }
    }

    @Test("Seed rows land on the Target")
    func seedRowsAreSnapped() throws {
        let target = try domedTarget()
        let snapper = try SurfaceSnapper(target: target)
        let cage = try partialCage()
        let seed = try WeaveFillDomain.grow(
            cage: cage, snapper: snapper, towards: fillPoint(), rows: 2
        )
        let cageVertices = Set(cage.liveFaceIDs().flatMap { cage.faceVertices($0) })
        let grown = Set(seed.seedFaces.flatMap { seed.mesh.faceVertices($0) })
            .subtracting(cageVertices)
        #expect(!grown.isEmpty)
        for v in grown {
            let p = try #require(seed.mesh.vertexPosition(v))
            let hit = try #require(snapper.snapToSurface(p))
            #expect(simd_length(hit.point - p) < 1e-5, "grown vertex is off the Target")
        }
    }

    @Test("A closed cage is refused — growing needs something to grow from")
    func closedCageRefused() throws {
        let snapper = try SurfaceSnapper(target: try domedTarget())
        #expect(throws: WeaveFillDomain.Failure.noOpenBoundary) {
            _ = try WeaveFillDomain.grow(
                cage: try closedCage(), snapper: snapper, towards: fillPoint()
            )
        }
    }

    @Test("Row count is derived from how far the paint reaches, and is capped")
    func rowsToCoverExtent() throws {
        let cage = try partialCage()
        let snapper = try SurfaceSnapper(target: try domedTarget())
        let seed = try WeaveFillDomain.grow(
            cage: cage, snapper: snapper, towards: fillPoint(), rows: 1
        )
        let stepLength = simd_length(seed.step)

        // A point one step out wants one row; three steps out wants three.
        let origin = seed.chain.compactMap { cage.vertexPosition($0) }
            .reduce(SIMD3<Float>.zero, +) / Float(seed.chain.count)
        let direction = seed.step / stepLength
        let one = WeaveFillDomain.rows(
            toCover: [origin + direction * stepLength * 0.9], from: seed.chain, of: cage,
            step: seed.step
        )
        let three = WeaveFillDomain.rows(
            toCover: [origin + direction * stepLength * 2.6], from: seed.chain, of: cage,
            step: seed.step
        )
        #expect(one == 1)
        #expect(three == 3)

        // Runaway paint is capped, not obeyed — each row is a ghost ring and a
        // sequential engine extrusion (the hazard task 4.2 already had to bound).
        let far = WeaveFillDomain.rows(
            toCover: [origin + direction * stepLength * 500], from: seed.chain, of: cage,
            step: seed.step, maximumRows: 12
        )
        #expect(far == 12)

        // Paint BEHIND the boundary asks for no growth, not negative growth.
        let behind = WeaveFillDomain.rows(
            toCover: [origin - direction * stepLength * 3], from: seed.chain, of: cage,
            step: seed.step
        )
        #expect(behind == 1)
    }

    @Test("A grown domain solves into clean quads on the prescribed boundary")
    func grownDomainSolves() throws {
        let cage = try partialCage()
        let snapper = try SurfaceSnapper(target: try domedTarget())
        let seed = try WeaveFillDomain.grow(
            cage: cage, snapper: snapper, towards: fillPoint(), rows: 2
        )

        var params = RemeshParameters()
        params.targetQuads = RegionWeaveSolver.prescribedQuadBudget(
            source: seed.mesh, regionFaces: seed.seedFaces
        ) ?? 8
        let solved = try #require(
            try seed.mesh.remeshedRegion(faces: seed.seedFaces, parameters: params)
        )
        let report = try #require(solved.regionReport())

        // The prescribed boundary survives bitwise — the whole point.
        for v in seed.chain {
            let before = try #require(cage.vertexPosition(v))
            let after = try #require(solved.vertexPosition(v))
            #expect(after.x.bitPattern == before.x.bitPattern)
            #expect(after.y.bitPattern == before.y.bitPattern)
            #expect(after.z.bitPattern == before.z.bitPattern)
        }
        // The artist's cage faces are untouched.
        for f in cage.liveFaceIDs() {
            #expect(solved.faceVertices(f) == cage.faceVertices(f))
        }
        #expect(report.interfaceVertices.count > 0)
    }
}

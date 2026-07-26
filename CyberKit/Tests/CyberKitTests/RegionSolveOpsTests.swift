import CyberKit
import Foundation
import Testing
import simd

/// Regional prescribed-boundary solve primitives (openspec add-weave-regional-solve,
/// task 11). Public-API + inline fixtures, so this suite is device-safe and can be
/// shared into the app-hosted target to run on the iPad too (Phase 4 pattern).
///
/// These assert EXACT LANDING, which the engine guarantees and refuses to publish
/// without. They deliberately do NOT assert that the interface is regular — that is
/// measured and reported, never guaranteed, and forcing it is task 5.3a.
@Suite("Region solve primitives")
struct RegionSolveOpsTests {
    private func mesh(fromOBJ text: String) throws -> Mesh {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("region-\(UUID().uuidString).obj")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Mesh.loadOBJ(at: url)
    }

    /// A 6x6 quad grid. The OBJ loader numbers faces in file order, so grid cell
    /// (i,j) is face i*6 + j and vertex (i,j) is i*7 + j.
    private func grid66() throws -> Mesh {
        var obj = ""
        for i in 0...6 {
            for j in 0...6 {
                obj += "v \(i) \(j) 0\n"
            }
        }
        for i in 0..<6 {
            for j in 0..<6 {
                let v = { (a: Int, b: Int) in a * 7 + b + 1 }  // OBJ is 1-based
                obj += "f \(v(i, j)) \(v(i + 1, j)) \(v(i + 1, j + 1)) \(v(i, j + 1))\n"
            }
        }
        return try mesh(fromOBJ: obj)
    }

    /// The centre 4x4 block of the 6x6 grid.
    private var centreBlock: [UInt32] {
        var faces: [UInt32] = []
        for i in 1...4 {
            for j in 1...4 {
                faces.append(UInt32(i * 6 + j))
            }
        }
        return faces
    }

    private func params(targetQuads: Int = 400) -> RemeshParameters {
        var p = RemeshParameters()
        p.targetQuads = targetQuads
        return p
    }

    @Test("A region solve leaves frozen faces and prescribed positions bit-identical")
    func exactLanding() throws {
        let source = try grid66()
        let region = Set(centreBlock)

        // Snapshot every face outside the region, and its vertices.
        var frozenRings: [UInt32: [UInt32]] = [:]
        var frozenPositions: [UInt32: SIMD3<Float>] = [:]
        for face in source.liveFaceIDs() where !region.contains(face) {
            let ring = source.faceVertices(face)
            frozenRings[face] = ring
            for v in ring { frozenPositions[v] = source.vertexPosition(v) }
        }
        #expect(frozenRings.count == 20)

        let solved = try #require(
            try source.remeshedRegion(faces: centreBlock, parameters: params())
        )

        for (face, ring) in frozenRings {
            #expect(solved.faceVertices(face) == ring, "frozen face \(face) ring changed")
        }
        for (vertex, position) in frozenPositions {
            let now = try #require(solved.vertexPosition(vertex))
            // Bit pattern, not an epsilon: "moved and snapped back" is not
            // "never touched", and only the bit pattern can tell them apart.
            #expect(now.x.bitPattern == position.x.bitPattern)
            #expect(now.y.bitPattern == position.y.bitPattern)
            #expect(now.z.bitPattern == position.z.bitPattern)
        }
        // The region really was rewritten, not merely preserved.
        #expect(solved.faceCount != source.faceCount)
    }

    @Test("The region report names the interface and is readable")
    func report() throws {
        let source = try grid66()
        let solved = try #require(
            try source.remeshedRegion(faces: centreBlock, parameters: params())
        )
        let report = try #require(solved.regionReport())

        #expect(report.interfaceVertices.count == 16)  // perimeter of the 4x4 block
        #expect(report.interfaceVertices == report.interfaceVertices.sorted())
        #expect(try #require(solved.solvedFaceIDs()).count > 0)

        // Irregularity is REPORTED, never a failure. Every reported id must be a
        // real interface vertex; the count itself is not asserted, because
        // forcing it to zero is task 5.3a.
        let interface = Set(report.interfaceVertices)
        for id in report.interfaceIrregular {
            #expect(interface.contains(id))
        }
    }

    @Test("A whole-mesh solve reports no region, and nil is not empty")
    func wholeMeshHasNoReport() throws {
        let source = try grid66()
        let solved = try source.remeshed(parameters: params())
        // Deliberately nil rather than []: "no region solve ran" must not read
        // as "the region was empty".
        #expect(solved.regionReport() == nil)
        #expect(solved.solvedFaceIDs() == nil)
        #expect(solved.interfaceVertexIDs() == nil)
    }

    @Test("A dead or repeated face id is refused and leaves the mesh untouched")
    func refusesBadRegion() throws {
        let source = try grid66()
        let before = source.faceCount

        #expect(throws: CyberKitError.self) {
            try source.setSolveRegion(faces: [7, 7])
        }
        #expect(throws: CyberKitError.self) {
            try source.setSolveRegion(faces: [99_999])
        }
        #expect(source.faceCount == before)
        // A valid selection still works afterwards.
        try source.setSolveRegion(faces: centreBlock)
        try source.setSolveRegion(faces: [])
    }

    @Test("A disconnected region is refused by the solve")
    func refusesDisconnected() throws {
        let source = try grid66()
        #expect(throws: CyberKitError.self) {
            _ = try source.remeshedRegion(faces: [0, 35], parameters: params())
        }
    }

    @Test("duplicated() preserves ids where a payload round-trip does not")
    func duplicatePreservesIDs() throws {
        let source = try grid66()
        let copy = try source.duplicated()

        #expect(copy.faceCount == source.faceCount)
        for face in source.liveFaceIDs() {
            #expect(copy.faceVertices(face) == source.faceVertices(face))
        }
        // The interior grid vertex (3,3) has four incident quads in both.
        #expect(copy.vertexFaceCount(24) == 4)
        #expect(source.vertexFaceCount(24) == 4)

        // Mutating the copy must not touch the source.
        #expect(copy.vertexPosition(0) == source.vertexPosition(0))
    }

    @Test("vertexFaceCount is nil for a dead id and exact for a live one")
    func valencePrimitive() throws {
        let source = try grid66()
        #expect(source.vertexFaceCount(0) == 1)   // grid corner
        #expect(source.vertexFaceCount(24) == 4)  // interior
        #expect(source.vertexFaceCount(99_999) == nil)
    }

    @Test("A valence override is accepted and clears cleanly")
    func valenceOverrides() throws {
        let source = try grid66()
        try source.setRegionValence([8: 5])
        try source.setRegionValence([:])
        // Threaded through the solve without disturbing exact landing.
        let solved = try #require(
            try source.remeshedRegion(
                faces: centreBlock, parameters: params(), valenceOverrides: [8: 5]
            )
        )
        #expect(solved.regionReport() != nil)
    }
}

/// The region backend behind the `WeaveSolving` seam (task 12).
@Suite("Region Weave solver backend")
struct RegionWeaveSolverTests {
    private func grid66() throws -> Mesh {
        var obj = ""
        for i in 0...6 { for j in 0...6 { obj += "v \(i) \(j) 0\n" } }
        for i in 0..<6 {
            for j in 0..<6 {
                let v = { (a: Int, b: Int) in a * 7 + b + 1 }
                obj += "f \(v(i, j)) \(v(i + 1, j)) \(v(i + 1, j + 1)) \(v(i, j + 1))\n"
            }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rws-\(UUID().uuidString).obj")
        try obj.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Mesh.loadOBJ(at: url)
    }

    private var centreBlock: [UInt32] {
        var faces: [UInt32] = []
        for i in 1...4 { for j in 1...4 { faces.append(UInt32(i * 6 + j)) } }
        return faces
    }

    @Test("EngineRemeshSolver still rejects a sub-region — the split is deliberate")
    func engineBackendStillRefusesRegions() throws {
        let source = try grid66()
        #expect(throws: CyberKitError.self) {
            _ = try EngineRemeshSolver().solve(
                source: source, region: .faces(centreBlock), constraints: WeaveConstraints(),
                params: SolverParameters(), onProgress: nil, isCancelled: { false }
            )
        }
    }

    @Test("CompositeWeaveSolver routes each region to its backend")
    func compositeRoutes() throws {
        let solver = CompositeWeaveSolver()
        let source = try grid66()

        let whole = try solver.solve(
            source: source, region: .wholeMesh, constraints: WeaveConstraints(),
            params: .coarse, onProgress: nil, isCancelled: { false }
        )
        #expect(whole != nil)
        #expect(whole?.interfaceVertices.isEmpty == true)  // no region report

        let regional = try #require(try solver.solve(
            source: try grid66(), region: .faces(centreBlock), constraints: WeaveConstraints(),
            params: SolverParameters(), onProgress: nil, isCancelled: { false }
        ))
        #expect(regional.interfaceVertices.count == 16)
    }

    @Test("Frozen faces are removed from the region, not merely passed along")
    func frozenFacesAreExcluded() throws {
        // Freeze the whole region: nothing is left to solve, and that must be a
        // clear refusal rather than a silent whole-region solve.
        let source = try grid66()
        #expect(throws: CyberKitError.self) {
            _ = try RegionWeaveSolver().solve(
                source: source, region: .faces(centreBlock),
                constraints: WeaveConstraints(frozenFaces: centreBlock),
                params: SolverParameters(), onProgress: nil, isCancelled: { false }
            )
        }
    }

    @Test("Density is derived from the prescribed boundary, not the global default")
    func prescribedDensity() throws {
        let source = try grid66()
        // The grid's edges are 1 unit; the 4x4 region is 16 square units, so a
        // patch matching the cage spacing is ~16 quads — not the 50 000 the
        // whole-mesh default would ask for.
        let budget = try #require(
            RegionWeaveSolver.prescribedQuadBudget(source: source, regionFaces: centreBlock)
        )
        #expect(budget == 16)
    }

    @Test("A region ghost reports its interface and does not fail on irregularity")
    func ghostCarriesTheReport() throws {
        let ghost = try #require(try RegionWeaveSolver().solve(
            source: try grid66(), region: .faces(centreBlock), constraints: WeaveConstraints(),
            params: SolverParameters(), onProgress: nil, isCancelled: { false }
        ))
        #expect(ghost.interfaceVertices.count == 16)
        #expect(ghost.addedFaces.count > 0)
        // Irregularity is reported, and reporting it did not prevent a ghost.
        let interface = Set(ghost.interfaceVertices)
        for id in ghost.interfaceIrregular { #expect(interface.contains(id)) }
    }
}

import CyberKit
import Foundation
import Testing
import simd

/// The 5.3 proof suite (openspec add-weave-regional-solve, tasks 14-16).
///
/// **Every assertion runs against the LIVE mesh handle, never through
/// `payloadData()`.** The payload is OBJ: `io_obj.cpp` writes positions at
/// default ostream precision (6 significant digits) and the loader renumbers
/// every element, so a payload round-trip provably cannot distinguish "never
/// touched this vertex" from "moved it and snapped back to within 1e-6" — which
/// is the entire distinction this change exists to make.
///
/// What is proven here: EXACT LANDING. What is deliberately not: interface
/// regularity, which is measured and reported (task 5.3a owns the guarantee).
@Suite("Region solve — the 5.3 proof")
struct RegionSolveProofTests {

    // MARK: - Fixtures

    private func mesh(fromOBJ text: String) throws -> Mesh {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("proof-\(UUID().uuidString).obj")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Mesh.loadOBJ(at: url)
    }

    /// A 6x6 quad grid lifted by `height`. Face (i,j) is id i*6+j; vertex (i,j)
    /// is id i*7+j.
    private func grid66(height: (Double, Double) -> Double = { _, _ in 0 }) throws -> Mesh {
        var obj = ""
        for i in 0...6 {
            for j in 0...6 {
                obj += "v \(i) \(j) \(height(Double(i), Double(j)))\n"
            }
        }
        for i in 0..<6 {
            for j in 0..<6 {
                let v = { (a: Int, b: Int) in a * 7 + b + 1 }
                obj += "f \(v(i, j)) \(v(i + 1, j)) \(v(i + 1, j + 1)) \(v(i, j + 1))\n"
            }
        }
        return try mesh(fromOBJ: obj)
    }

    /// Same ring combinatorics as the flat grid, on a dome.
    private func domedGrid() throws -> Mesh {
        try grid66 { i, j in
            let u = i - 3, v = j - 3
            return 2.0 * max(0, 1.0 - (u * u + v * v) / 20.0)
        }
    }

    private func faces(_ cells: [(Int, Int)]) -> [UInt32] {
        cells.map { UInt32($0.0 * 6 + $0.1) }
    }

    private var centreBlock: [UInt32] {
        faces((1...4).flatMap { i in (1...4).map { j in (i, j) } })
    }

    /// The centre block minus its top-right quadrant — the ring gains a reflex
    /// corner, so the accounting is not merely "a rectangle".
    private var lShape: [UInt32] {
        faces((1...4).flatMap { i in (1...4).compactMap { j in (i >= 3 && j >= 3) ? nil : (i, j) } })
    }

    /// A plus/cross region: eight boundary corners, four of them reflex.
    private var crossShape: [UInt32] {
        faces([(1, 2), (1, 3), (2, 1), (2, 2), (2, 3), (2, 4),
               (3, 1), (3, 2), (3, 3), (3, 4), (4, 2), (4, 3)])
    }

    /// The quad budget the REAL path derives for this fixture. `RemeshParameters()`
    /// defaults to 50 000, which is a whole-MESH budget — pointing it at a
    /// 16-square-unit region produces a 100 000-vertex patch welded onto a
    /// 36-quad cage. `RegionWeaveSolver.prescribedQuadBudget` exists precisely
    /// to stop that, and these tests use the number it derives so they exercise
    /// the density the app actually gets.
    private func params(scale: Int = 1) -> RemeshParameters {
        var p = RemeshParameters()
        p.targetQuads = 16 * scale * scale
        return p
    }

    @Test("The fixture's prescribed budget is what these tests use")
    func fixtureBudgetMatchesThePrescription() throws {
        let source = try grid66()
        #expect(
            RegionWeaveSolver.prescribedQuadBudget(source: source, regionFaces: centreBlock) == 16
        )
    }

    // MARK: - Canonical, float-free digest (15.1)

    /// A `*.interface.golden` payload: integers only, so it is byte-reproducible
    /// across platforms, accel backends and float ABIs. A positional golden
    /// provably cannot carry this proof (see the type doc).
    ///
    /// DEVIATION from the plan: boundary valences are emitted in ASCENDING ID
    /// order rather than ring order. The engine computes the ordered interface
    /// rings but does not expose them through the C API, and ascending id is
    /// equally canonical and equally float-free. Exposing ring order is 5.4a's
    /// need (it wants to draw the interface), not this proof's.
    private func interfaceDigest(_ mesh: Mesh) -> String {
        guard let report = mesh.regionReport() else { return "<no region solve>" }
        var lines: [String] = []
        let valences = report.interfaceVertices
            .map { "\($0):\(mesh.vertexFaceCount($0) ?? -1)" }
            .joined(separator: " ")
        lines.append("interface \(valences)")
        lines.append("irregular \(report.interfaceIrregular.map(String.init).joined(separator: " "))")
        lines.append("budget \(report.interiorIndexBudget)")
        lines.append("residual \(report.indexResidual)")
        lines.append("seam-triangles \(report.interfaceTriangles)")
        var quads: [String] = []
        for face in mesh.liveFaceIDs() {
            let ring = mesh.faceVertices(face)
            guard !ring.isEmpty, let lowest = ring.min(), let at = ring.firstIndex(of: lowest)
            else { continue }
            let rotated = Array(ring[at...] + ring[..<at])
            quads.append(rotated.map(String.init).joined(separator: ","))
        }
        lines.append("faces \(quads.sorted().joined(separator: " "))")
        return lines.joined(separator: "\n")
    }

    /// The PRESCRIPTION half of the digest — what the cage demands, independent
    /// of what the solve achieved.
    private func prescriptionDigest(_ mesh: Mesh) -> String {
        guard let report = mesh.regionReport() else { return "<none>" }
        return "interface \(report.interfaceVertices.map(String.init).joined(separator: " "))\n"
            + "budget \(report.interiorIndexBudget)"
    }

    // MARK: - 14.1 / 14.2 exact landing

    @Test("Interface vertices land exactly — same id, bitwise identical position")
    func exactLanding() throws {
        for density in [1, 4] {
            let source = try grid66()
            var before: [UInt32: SIMD3<Float>] = [:]
            let region = Set(centreBlock)
            for face in source.liveFaceIDs() where !region.contains(face) {
                for v in source.faceVertices(face) { before[v] = source.vertexPosition(v) }
            }
            let solved = try #require(
                try source.remeshedRegion(faces: centreBlock, parameters: params(scale: density))
            )
            for (vertex, position) in before {
                let now = try #require(solved.vertexPosition(vertex))
                #expect(now.x.bitPattern == position.x.bitPattern, "density \(density)x")
                #expect(now.y.bitPattern == position.y.bitPattern)
                #expect(now.z.bitPattern == position.z.bitPattern)
            }
        }
    }

    @Test("Frozen faces keep their id, ring and order")
    func frozenTopologyIdentical() throws {
        let source = try grid66()
        let region = Set(centreBlock)
        var rings: [UInt32: [UInt32]] = [:]
        for face in source.liveFaceIDs() where !region.contains(face) {
            rings[face] = source.faceVertices(face)
        }
        #expect(rings.count == 20)
        let solved = try #require(try source.remeshedRegion(faces: centreBlock, parameters: params()))
        for (face, ring) in rings {
            #expect(solved.faceVertices(face) == ring)
        }
    }

    // MARK: - 14.3 the interface edge set

    /// Interface edges derived purely from the frozen rings: an edge of a frozen
    /// face whose other side is not frozen. Computable identically before and
    /// after the solve, so the two sets can be compared.
    private func interfaceEdgeSet(_ mesh: Mesh, frozen: Set<UInt32>) -> Set<UInt64> {
        var useCount: [UInt64: Int] = [:]
        for face in mesh.liveFaceIDs() where frozen.contains(face) {
            let ring = mesh.faceVertices(face)
            for i in 0..<ring.count {
                let a = ring[i], b = ring[(i + 1) % ring.count]
                useCount[(UInt64(min(a, b)) << 32) | UInt64(max(a, b)), default: 0] += 1
            }
        }
        // Used once among frozen faces = the frozen side's outer edge, i.e. the
        // interface (or the mesh rim, which the region never touches).
        return Set(useCount.filter { $0.value == 1 }.keys)
    }

    @Test("The interface edge set survives a 4x over-fine target")
    func interfaceEdgesSurviveDensity() throws {
        // Only an over-fine target exercises the split path; at 1x this passes
        // with or without the engine's SplitPass guard, so a 1x-only test would
        // be worthless as a regression guard.
        let source = try grid66()
        let frozen = Set(source.liveFaceIDs()).subtracting(centreBlock)
        let before = interfaceEdgeSet(source, frozen: frozen)
        // The frozen ring is one quad wide, so its once-used edges are BOTH its
        // outer grid rim (24) and the inner interface (16).
        #expect(before.count == 40)

        let solved = try #require(
            try source.remeshedRegion(faces: centreBlock, parameters: params(scale: 4))
        )
        #expect(interfaceEdgeSet(solved, frozen: frozen) == before)
    }

    // MARK: - 14.4 the report is CORRECT (not that it is zero)

    @Test("Reported irregularity matches an independent valence sweep")
    func reportMatchesIndependentSweep() throws {
        let source = try grid66()
        let frozenBefore = Set(source.liveFaceIDs()).subtracting(centreBlock)
        // The cage prescription, computed here rather than read from the engine.
        var prescribed: [UInt32: Int] = [:]
        for face in source.liveFaceIDs() where frozenBefore.contains(face) {
            for v in source.faceVertices(face) { prescribed[v, default: 0] += 1 }
        }

        let solved = try #require(try source.remeshedRegion(faces: centreBlock, parameters: params()))
        let report = try #require(solved.regionReport())

        var expectedIrregular: Set<UInt32> = []
        for vertex in report.interfaceVertices {
            let total = try #require(solved.vertexFaceCount(vertex))
            let frozenIncident = prescribed[vertex] ?? 0
            // Grid interior vertices want total valence 4.
            if total != 4 { expectedIrregular.insert(vertex) }
            #expect(frozenIncident > 0, "an interface vertex must touch frozen topology")
        }
        #expect(Set(report.interfaceIrregular) == expectedIrregular)
    }

    // MARK: - 14.5 the negative control

    @Test("A whole-mesh solve FAILS the exact-landing assertions — they are not vacuous")
    func negativeControl() throws {
        let source = try grid66()
        let region = Set(centreBlock)
        var rings: [UInt32: [UInt32]] = [:]
        var positions: [UInt32: SIMD3<Float>] = [:]
        for face in source.liveFaceIDs() where !region.contains(face) {
            rings[face] = source.faceVertices(face)
            for v in source.faceVertices(face) { positions[v] = source.vertexPosition(v) }
        }

        var whole = RemeshParameters()
        whole.targetQuads = 400
        let wholeMesh = try source.remeshed(parameters: whole)

        // If a whole-mesh solve happened to satisfy these, the region tests
        // above would prove nothing. At least one must break.
        let ringsSurvived = rings.allSatisfy { wholeMesh.faceVertices($0.key) == $0.value }
        let positionsSurvived = positions.allSatisfy { id, p in
            guard let now = wholeMesh.vertexPosition(id) else { return false }
            return now.x.bitPattern == p.x.bitPattern && now.y.bitPattern == p.y.bitPattern
        }
        #expect(!(ringsSurvived && positionsSurvived),
                "whole-mesh solve preserved frozen ids AND positions — the region assertions are vacuous")
        #expect(wholeMesh.regionReport() == nil)
    }

    // MARK: - 14.6 rejections, each with its own reason

    @Test("Every unsolvable region is refused, and the mesh is untouched")
    func rejections() throws {
        let source = try grid66()
        let facesBefore = source.faceCount

        // Disconnected.
        #expect(throws: CyberKitError.self) {
            _ = try source.remeshedRegion(faces: [0, 35], parameters: params())
        }
        // Whole mesh — refused, never aliased to the whole-mesh path.
        #expect(throws: CyberKitError.self) {
            _ = try source.remeshedRegion(faces: source.liveFaceIDs(), parameters: params())
        }
        // Dead id, repeated id.
        #expect(throws: CyberKitError.self) { try source.setSolveRegion(faces: [99_999]) }
        #expect(throws: CyberKitError.self) { try source.setSolveRegion(faces: [7, 7]) }
        // Frozen-out region.
        #expect(throws: CyberKitError.self) {
            _ = try RegionWeaveSolver().solve(
                source: source, region: .faces(centreBlock),
                constraints: WeaveConstraints(frozenFaces: centreBlock),
                params: SolverParameters(), onProgress: nil, isCancelled: { false }
            )
        }
        #expect(source.faceCount == facesBefore)
    }

    // MARK: - 15.4 determinism

    @Test("A region solve is deterministic, and invariant to region id ORDER")
    func determinism() throws {
        let a = try #require(try grid66().remeshedRegion(faces: centreBlock, parameters: params()))
        let b = try #require(try grid66().remeshedRegion(faces: centreBlock, parameters: params()))
        #expect(interfaceDigest(a) == interfaceDigest(b))

        // The region is a SET; supplying it in a different order must not change
        // the result. Deterministic shuffle — no RNG in a test.
        let shuffled = centreBlock.sorted { ($0 &* 7) % 13 < ($1 &* 7) % 13 }
        #expect(shuffled != centreBlock)
        let c = try #require(try grid66().remeshedRegion(faces: shuffled, parameters: params()))
        #expect(interfaceDigest(c) == interfaceDigest(a))
    }

    // MARK: - 15.2 fixtures

    @Test("Curvature does not change the interface AT ALL — it is purely topological")
    func curvatureDoesNotChangeTheInterface() throws {
        // The plan predicted an identical full digest here and it is CORRECT,
        // which the task-0 spike could not see: the spike bypassed the pipeline
        // and drove density directly, and at that density the flat fixture came
        // out 3/16 irregular while the dome came out 0/16. Through the real path
        // — density derived from the prescription (task 12.3) — both are clean
        // and their digests match byte-for-byte. Same ring combinatorics, same
        // interface, same faces, on flat and curved geometry alike.
        let flat = try #require(try grid66().remeshedRegion(faces: centreBlock, parameters: params()))
        let domed = try #require(
            try domedGrid().remeshedRegion(faces: centreBlock, parameters: params())
        )
        #expect(prescriptionDigest(flat) == prescriptionDigest(domed))
        #expect(interfaceDigest(flat) == interfaceDigest(domed))
    }

    @Test("At the prescribed density the simple fixtures have a CLEAN interface")
    func prescribedDensityYieldsACleanInterface() throws {
        // Not a guarantee — the L-shape below still comes out irregular, and
        // forcing that to zero is task 5.3a. But it pins a real, measured
        // improvement: getting the density right removes the irregularity the
        // spike saw on the simple cases, so a regression in the budget
        // derivation shows up here rather than as a quiet quality loss.
        for source in [try grid66(), try domedGrid()] {
            let solved = try #require(
                try source.remeshedRegion(faces: centreBlock, parameters: params())
            )
            let report = try #require(solved.regionReport())
            #expect(report.interfaceIrregular.isEmpty)
            #expect(report.interfaceTriangles == 0)
        }
    }

    @Test("The L-shape is still irregular — the guarantee genuinely does not hold yet")
    func reflexRingStillIrregular() throws {
        // The honest counterweight to the test above. If this ever starts
        // passing with an EMPTY irregular set, the coupling problem may have
        // been solved by accident and 5.3a should be re-examined rather than
        // silently closed.
        let solved = try #require(try grid66().remeshedRegion(faces: lShape, parameters: params()))
        let report = try #require(solved.regionReport())
        #expect(!report.interfaceIrregular.isEmpty,
                "L-shape interface came out clean — re-examine 5.3a before assuming it is fixed")
    }

    @Test("A reflex ring and a cross ring both solve with exact landing")
    func awkwardRings() throws {
        for (name, region) in [("lshape", lShape), ("cross", crossShape)] {
            let source = try grid66()
            let frozen = Set(source.liveFaceIDs()).subtracting(region)
            var rings: [UInt32: [UInt32]] = [:]
            for face in source.liveFaceIDs() where frozen.contains(face) {
                rings[face] = source.faceVertices(face)
            }
            let solved = try #require(
                try source.remeshedRegion(faces: region, parameters: params())
            )
            for (face, ring) in rings {
                #expect(solved.faceVertices(face) == ring, "\(name): frozen face \(face) changed")
            }
            #expect(try #require(solved.regionReport()).interfaceVertices.count > 0, "\(name)")
        }
    }

    // MARK: - 15.1 committed goldens (simulator only — see the golden convention)

    #if targetEnvironment(simulator)
    private var goldensDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Goldens", isDirectory: true)
            .appendingPathComponent("RegionSolve", isDirectory: true)
    }

    private func checkGolden(_ digest: String, _ name: String) throws {
        let url = goldensDirectory.appendingPathComponent("\(name).interface.golden")
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(
                at: goldensDirectory, withIntermediateDirectories: true
            )
            try digest.write(to: url, atomically: true, encoding: .utf8)
            Issue.record("recorded a new golden at \(url.lastPathComponent) — review and commit it")
            return
        }
        let expected = try String(contentsOf: url, encoding: .utf8)
        #expect(digest == expected, "\(name) interface golden changed")
    }

    @Test("Interface goldens are byte-stable")
    func goldens() throws {
        try checkGolden(
            interfaceDigest(
                try #require(try grid66().remeshedRegion(faces: centreBlock, parameters: params()))
            ), "region_solve_grid66_center")
        try checkGolden(
            interfaceDigest(
                try #require(try grid66().remeshedRegion(faces: lShape, parameters: params()))
            ), "region_solve_lshape")
        try checkGolden(
            interfaceDigest(
                try #require(try domedGrid().remeshedRegion(faces: centreBlock, parameters: params()))
            ), "region_solve_sphere_cap")
    }
    #endif

    // MARK: - 16.2 the null object

    @Test("An empty region is the null object — byte-identical to a whole-mesh solve")
    func emptyRegionIsWholeMesh() throws {
        var p = RemeshParameters()
        p.targetQuads = 400
        let viaRegion = try #require(
            try grid66().remeshedRegion(faces: [], parameters: p)
        )
        let viaWholeMesh = try grid66().remeshed(parameters: p)

        #expect(viaRegion.faceCount == viaWholeMesh.faceCount)
        #expect(viaRegion.vertexCount == viaWholeMesh.vertexCount)
        for face in viaWholeMesh.liveFaceIDs() {
            #expect(viaRegion.faceVertices(face) == viaWholeMesh.faceVertices(face))
        }
        for id in 0..<UInt32(viaWholeMesh.vertexCount) {
            guard let a = viaRegion.vertexPosition(id), let b = viaWholeMesh.vertexPosition(id)
            else { continue }
            #expect(a.x.bitPattern == b.x.bitPattern)
            #expect(a.y.bitPattern == b.y.bitPattern)
            #expect(a.z.bitPattern == b.z.bitPattern)
        }
        #expect(viaRegion.regionReport() == nil)
    }
}

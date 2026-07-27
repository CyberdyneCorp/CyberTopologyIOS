import CyberKit
import Foundation
import Testing
import simd

/// Implicit sizing from a prescribed interface (openspec add-implicit-interface-sizing,
/// 5.5a): a region solve derives its quad budget from the boundary it must land on, so an
/// auto-filled region matches the surrounding cage's scale with no density dial.
///
/// These lock behaviour that 5.5a's spike found ALREADY WORKING — it fell out of
/// `add-weave-constraint-authoring` subtracting frozen faces before the budget is derived,
/// meeting a derivation that was already spacing-based. Locking it matters precisely
/// because nobody implemented it deliberately: without these assertions a refactor could
/// swap the derivation for a face count and every existing test would still pass.
@Suite("Implicit sizing from a prescribed interface")
struct ImplicitInterfaceSizingTests {
    private func mesh(_ obj: String) throws -> Mesh {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sizing-\(UUID().uuidString).obj")
        try obj.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Mesh.loadOBJ(at: url)
    }

    private func grid(_ n: Int, spacing: Float) throws -> Mesh {
        var obj = ""
        for i in 0...n {
            for j in 0...n { obj += "v \(Float(i) * spacing) \(Float(j) * spacing) 0\n" }
        }
        for i in 0..<n {
            for j in 0..<n {
                let v = { (a: Int, b: Int) in a * (n + 1) + b + 1 }
                obj += "f \(v(i, j)) \(v(i + 1, j)) \(v(i + 1, j + 1)) \(v(i, j + 1))\n"
            }
        }
        return try mesh(obj)
    }

    /// The centre 4x4 block of a 6x6 grid.
    private var centreBlock: [UInt32] {
        var faces: [UInt32] = []
        for i in 1...4 {
            for j in 1...4 { faces.append(UInt32(i * 6 + j)) }
        }
        return faces
    }

    // MARK: - The property that makes the sizing implicit

    @Test("The budget follows INTERFACE SPACING, not the region's face count")
    func followsSpacingNotFaceCount() throws {
        // On a uniform grid area/spacing^2 == face count, so a grid cannot tell the two
        // apart. ONE square face whose boundary is subdivided into 8 half-length edges
        // can: area 1, mean interface edge 0.5, so a spacing-derived budget is 4 while
        // the face count is 1.
        var obj = ""
        for (x, y) in [
            (Float(0), Float(0)), (0.5, 0), (1, 0), (1, 0.5),
            (1, 1), (0.5, 1), (0, 1), (0, 0.5),
        ] {
            obj += "v \(x) \(y) 0\n"
        }
        obj += "f 1 2 3 4 5 6 7 8\n"
        let octagon = try mesh(obj)

        let faces = octagon.liveFaceIDs()
        #expect(faces.count == 1)
        let budget = try #require(
            RegionWeaveSolver.prescribedQuadBudget(source: octagon, regionFaces: faces)
        )
        // Concatenation would make this a String, and #expect wants a Comment literal.
        #expect(budget == 4, "spacing-derived budget is area/spacing^2 = 4; 1 means it counted faces")
    }

    @Test("The budget is SCALE-INVARIANT: the same cage at half spacing asks for the same quads")
    func scaleInvariant() throws {
        let coarse = try #require(
            RegionWeaveSolver.prescribedQuadBudget(
                source: try grid(6, spacing: 1), regionFaces: centreBlock
            )
        )
        let fine = try #require(
            RegionWeaveSolver.prescribedQuadBudget(
                source: try grid(6, spacing: 0.5), regionFaces: centreBlock
            )
        )
        // This is what "matches manual scale with no dials" means: the budget tracks the
        // cage's own proportions, not the document's absolute units. A budget that grew
        // when the model was scaled down would need a dial to correct it.
        #expect(coarse == fine, "budget must not depend on absolute scale")
    }

    // MARK: - Frozen patches contribute to the interface

    @Test("Freezing a patch inside a region re-derives the budget from the new interface")
    func frozenPatchChangesTheBudget() throws {
        let source = try grid(6, spacing: 1)
        let block = try #require(
            RegionWeaveSolver.prescribedQuadBudget(source: source, regionFaces: centreBlock)
        )

        // Freeze the inner 2x2: the solved region becomes an annulus whose interface now
        // includes the frozen patch's own boundary.
        var frozen: Set<UInt32> = []
        for i in 2...3 {
            for j in 2...3 { frozen.insert(UInt32(i * 6 + j)) }
        }
        let annulus = centreBlock.filter { !frozen.contains($0) }
        let withFrozen = try #require(
            RegionWeaveSolver.prescribedQuadBudget(source: source, regionFaces: annulus)
        )

        #expect(withFrozen < block, "a frozen patch removes area, so the budget must shrink")
        #expect(withFrozen == annulus.count, "on a unit grid the budget matches solved faces")
    }

    @Test("The solve USES the derived budget, overriding whatever the caller asked for")
    func derivedBudgetOverridesTheCallerPreset() throws {
        // The bug this guards shipped once already, in reverse: a region inheriting the
        // whole-mesh preset fought the pinned interface and welded a wildly over-fine
        // patch onto a coarse cage. So a deliberately absurd preset must NOT survive.
        let absurd = SolverParameters.fine  // 4000 quads for a 16-face block
        let ghost = try #require(
            try RegionWeaveSolver().solve(
                source: try grid(6, spacing: 1), region: .faces(centreBlock),
                constraints: WeaveConstraints(), params: absurd,
                onProgress: nil, isCancelled: { false }
            )
        )
        // The cage is 36 unit quads; a 4000-quad preset would produce orders of magnitude
        // more. The derived budget keeps it near the prescription instead.
        #expect(
            ghost.mesh.faceCount < 400,
            "face count \(ghost.mesh.faceCount) suggests the caller's preset won"
        )
    }

    @Test("A region with no measurable interface declines rather than guessing")
    func noInterfaceDeclines() throws {
        // Empty region: nothing to derive a spacing from. nil is the honest answer, and
        // the caller then keeps its own parameters rather than receiving a fabricated one.
        #expect(
            RegionWeaveSolver.prescribedQuadBudget(
                source: try grid(6, spacing: 1), regionFaces: []
            ) == nil
        )
    }
}

/// External projection surface for a region solve (openspec add-region-external-reference,
/// 5.4b). The engine tests own the DEVIATION property; these own the Swift contract —
/// that the side-channel is wired, inert when unset, and refuses what it should.
@Suite("Region solves can project onto an external reference")
struct RegionExternalReferenceTests {
    private func mesh(_ obj: String) throws -> Mesh {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("extref-\(UUID().uuidString).obj")
        try obj.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Mesh.loadOBJ(at: url)
    }

    /// A rippled grid: detail finer than a coarse cage, the only geometry where the
    /// defect is visible at all.
    private func rippled(_ n: Int) throws -> Mesh {
        var obj = ""
        for i in 0...n {
            for j in 0...n {
                let u = 2 * Float(i) / Float(n) - 1
                let v = 2 * Float(j) / Float(n) - 1
                obj += "v \(u) \(v) \(0.12 * sin(9 * u) * cos(9 * v))\n"
            }
        }
        for i in 0..<n {
            for j in 0..<n {
                let f = { (a: Int, b: Int) in a * (n + 1) + b + 1 }
                obj += "f \(f(i, j)) \(f(i + 1, j)) \(f(i + 1, j + 1)) \(f(i, j + 1))\n"
            }
        }
        return try mesh(obj)
    }

    private var centreBlock: [UInt32] {
        var faces: [UInt32] = []
        for i in 1...4 {
            for j in 1...4 { faces.append(UInt32(i * 6 + j)) }
        }
        return faces
    }

    /// A SMALL explicit budget. `RemeshParameters()` carries the engine's raw default of
    /// 50 000 target quads, and `remeshedRegion` does not derive one — that is
    /// `RegionWeaveSolver`'s job — so the bare initialiser asks for 50 000 quads inside a
    /// 16-face region and the solve runs effectively forever.
    private var params: RemeshParameters {
        var p = RemeshParameters()
        p.targetQuads = 64
        return p
    }

    @Test("Setting and clearing a reference is accepted")
    func setAndClear() throws {
        let cage = try rippled(6)
        let target = try rippled(24)
        try cage.setRegionReference(target)
        try cage.setRegionReference(nil)
    }

    @Test("A mesh cannot be its own reference")
    func selfReferenceRefused() throws {
        let cage = try rippled(6)
        // Projecting onto the mesh being rewritten IS the default, so accepting this
        // would be a call that looks like it does something and does nothing.
        #expect(throws: (any Error).self) { try cage.setRegionReference(cage) }
    }

    @Test("A reference changes the solve; clearing it restores the original result")
    func referenceChangesTheSolveAndClears() throws {
        let plainCage = try rippled(6)
        let plain = try #require(
            try plainCage.remeshedRegion(faces: centreBlock, parameters: params)
        )

        let referencedCage = try rippled(6)
        let target = try rippled(24)
        try referencedCage.setRegionReference(target)
        let referenced = try #require(
            try referencedCage.remeshedRegion(faces: centreBlock, parameters: params)
        )
        // If the side-channel were not wired, these would be identical — which is
        // exactly how a stored-and-never-read parameter looks from outside.
        #expect(try plain.payloadData() != referenced.payloadData())

        // And clearing must genuinely restore the default, not leave a sticky reference.
        let clearedCage = try rippled(6)
        try clearedCage.setRegionReference(target)
        try clearedCage.setRegionReference(nil)
        let cleared = try #require(
            try clearedCage.remeshedRegion(faces: centreBlock, parameters: params)
        )
        #expect(try cleared.payloadData() == plain.payloadData())
    }

    @Test("A reference does not disturb the interface")
    func interfaceUnaffected() throws {
        let cage = try rippled(6)
        let target = try rippled(24)
        try cage.setRegionReference(target)
        let solved = try #require(
            try cage.remeshedRegion(faces: centreBlock, parameters: params)
        )
        let report = try #require(solved.regionReport())
        // Exact landing is 5.3's shipped guarantee and must not depend on which surface
        // the INTERIOR was projected onto.
        #expect(!report.interfaceVertices.isEmpty)
        for vertex in report.interfaceVertices {
            #expect(solved.vertexPosition(vertex) == cage.vertexPosition(vertex))
        }
    }
}

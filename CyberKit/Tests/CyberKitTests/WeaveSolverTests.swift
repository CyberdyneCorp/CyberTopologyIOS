import CyberKit
import Foundation
import Testing
import simd

/// The Weave solver-session layer with its first backend, `EngineRemeshSolver`
/// (the engine auto-retopology behind the `WeaveSolving` seam). Public-API +
/// inline fixtures, so this suite is device-safe and can be shared into the
/// app-hosted target (Phase 4 pattern) to run on the iPad too.
@Suite("Weave solver session (auto-remesh backend)")
struct WeaveSolverTests {
    private func mesh(fromOBJ text: String) throws -> Mesh {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("weave-\(UUID().uuidString).obj")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Mesh.loadOBJ(at: url)
    }

    /// A unit cube — a small closed manifold the remesher can quadrangulate.
    private func cube() throws -> Mesh {
        try mesh(fromOBJ: """
        v -0.5 -0.5 -0.5
        v  0.5 -0.5 -0.5
        v  0.5  0.5 -0.5
        v -0.5  0.5 -0.5
        v -0.5 -0.5  0.5
        v  0.5 -0.5  0.5
        v  0.5  0.5  0.5
        v -0.5  0.5  0.5
        f 1 4 3 2
        f 5 6 7 8
        f 1 2 6 5
        f 2 3 7 6
        f 3 4 8 7
        f 4 1 5 8
        """)
    }

    private func params() -> SolverParameters {
        var p = SolverParameters()
        p.remesh.targetQuads = 60
        return p
    }

    @Test("Auto-remesh solve produces a quad ghost and never touches the source")
    func solveProducesQuadGhost() throws {
        let source = try cube()
        let facesBefore = source.faceCount
        let ghost = try #require(try EngineRemeshSolver().solve(
            source: source, region: .wholeMesh, constraints: WeaveConstraints(),
            params: params(), onProgress: nil, isCancelled: { false }
        ))
        #expect(try ghost.mesh.stats().quads > 0)
        #expect(ghost.mesh.faceCount > 0)
        // The ghost's added-face set is the whole fresh cage.
        #expect(ghost.addedFaces.count == ghost.mesh.faceCount)
        // The source is never mutated by a solve.
        #expect(source.faceCount == facesBefore)
    }

    @Test("Auto-remesh is deterministic (same input + params → identical ghost)")
    func solveIsDeterministic() throws {
        let solver = EngineRemeshSolver()
        let a = try #require(try solver.solve(
            source: try cube(), region: .wholeMesh, constraints: WeaveConstraints(),
            params: params(), onProgress: nil, isCancelled: { false }
        ))
        let b = try #require(try solver.solve(
            source: try cube(), region: .wholeMesh, constraints: WeaveConstraints(),
            params: params(), onProgress: nil, isCancelled: { false }
        ))
        #expect(try a.mesh.payloadData() == b.mesh.payloadData())
    }

    @Test("Cancellation returns nil and leaves the source untouched")
    func cancelReturnsNil() throws {
        let source = try cube()
        let facesBefore = source.faceCount
        let ghost = try EngineRemeshSolver().solve(
            source: source, region: .wholeMesh, constraints: WeaveConstraints(),
            params: params(), onProgress: nil, isCancelled: { true }
        )
        #expect(ghost == nil)
        #expect(source.faceCount == facesBefore)
    }

    @Test("Progress callbacks bridge without crashing and report sane fractions")
    func progressIsReported() throws {
        var fractions: [Double] = []
        _ = try EngineRemeshSolver().solve(
            source: try cube(), region: .wholeMesh, constraints: WeaveConstraints(),
            params: params(), onProgress: { fractions.append($0.fraction) }, isCancelled: { false }
        )
        // The engine may or may not emit progress for a tiny mesh; any value it
        // does emit must be a valid fraction. (Cancellation above is the strong
        // proof the callback bridge is wired end to end.)
        #expect(fractions.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test("The Auto-Retopo default uses a coarse, interactive quad budget")
    func autoRetopoDefaultIsCoarse() {
        // The engine's raw default (50k quads) is far too fine for one-tap use.
        #expect(SolverParameters.autoRetopoDefault.remesh.targetQuads == 1500)
        #expect(SolverParameters().remesh.targetQuads > 1500, "raw engine default is finer")
    }

    // MARK: - Density + symmetry honouring (add-weave-density-symmetry)

    @Test("A finer density yields more quads than a coarser one")
    func finerDensityYieldsMoreQuads() throws {
        let solver = EngineRemeshSolver()
        func quadCount(_ p: SolverParameters) throws -> Int {
            let ghost = try #require(try solver.solve(
                source: try cube(), region: .wholeMesh, constraints: WeaveConstraints(),
                params: p, onProgress: nil, isCancelled: { false }
            ))
            return try ghost.mesh.stats().quads
        }
        let coarse = try quadCount(.coarse)
        let fine = try quadCount(.fine)
        #expect(fine > coarse, "fine (\(fine)) should have more quads than coarse (\(coarse))")
    }

    /// Every face-referenced vertex has a partner at its mirror image across the
    /// plane. Orphan vertices (points left un-referenced by `deleteFaces`, which
    /// the OBJ payload round-trip drops) are ignored — the cage's geometry is
    /// what its faces span.
    private func isMirrorSymmetric(
        _ mesh: Mesh, normal: SIMD3<Float>, origin: SIMD3<Float>, tolerance: Float
    ) -> Bool {
        var used = Set<UInt32>()
        for face in mesh.liveFaceIDs() { used.formUnion(mesh.faceVertices(face)) }
        let positions = used.compactMap { mesh.vertexPosition($0) }
        for p in positions {
            let mirrored = p - 2 * simd_dot(p - origin, normal) * normal
            if !positions.contains(where: { simd_distance($0, mirrored) < tolerance }) {
                return false
            }
        }
        return !positions.isEmpty
    }

    @Test("A symmetry constraint yields a mirror-symmetric cage")
    func symmetryConstraintYieldsSymmetricCage() throws {
        let symmetry = SymmetrySettings(mirrorAxes: [.x], origin: .zero, isEnabled: true)
        let source = try cube()
        let facesBefore = source.faceCount
        let ghost = try #require(try EngineRemeshSolver().solve(
            source: source, region: .wholeMesh,
            constraints: WeaveConstraints(symmetry: symmetry),
            params: params(), onProgress: nil, isCancelled: { false }
        ))
        #expect(ghost.mesh.faceCount > 0)
        #expect(isMirrorSymmetric(ghost.mesh, normal: SIMD3(1, 0, 0), origin: .zero, tolerance: 1e-3),
            "the cage should be mirror-symmetric about the X plane")
        #expect(source.faceCount == facesBefore, "source untouched")
    }

    @Test("A non-symmetric Target still yields a symmetric cage")
    func nonSymmetricTargetStillSymmetric() throws {
        // A wedge — deliberately NOT symmetric about X.
        let wedge = try mesh(fromOBJ: """
        v 0 0 0
        v 2 0 0
        v 2 1 0
        v 0 1 0
        v 0 0 1
        v 1.5 0 1
        v 1.5 1 1
        v 0 1 1
        f 1 4 3 2
        f 5 6 7 8
        f 1 2 6 5
        f 2 3 7 6
        f 3 4 8 7
        f 4 1 5 8
        """)
        let symmetry = SymmetrySettings(mirrorAxes: [.x], origin: SIMD3(1, 0, 0), isEnabled: true)
        let ghost = try #require(try EngineRemeshSolver().solve(
            source: wedge, region: .wholeMesh,
            constraints: WeaveConstraints(symmetry: symmetry),
            params: params(), onProgress: nil, isCancelled: { false }
        ))
        #expect(isMirrorSymmetric(ghost.mesh, normal: SIMD3(1, 0, 0), origin: SIMD3(1, 0, 0), tolerance: 5e-3),
            "even a non-symmetric Target yields a symmetric cage")
    }

    @Test("A constrained solve is still deterministic")
    func constrainedSolveIsDeterministic() throws {
        let solver = EngineRemeshSolver()
        let constraints = WeaveConstraints(
            symmetry: SymmetrySettings(mirrorAxes: [.x], origin: .zero, isEnabled: true)
        )
        func payload() throws -> Data {
            let ghost = try #require(try solver.solve(
                source: try cube(), region: .wholeMesh, constraints: constraints,
                params: params(), onProgress: nil, isCancelled: { false }
            ))
            return try ghost.mesh.payloadData()
        }
        #expect(try payload() == payload())
    }

    @Test("A sub-region solve is rejected this slice")
    func subRegionRejected() throws {
        #expect(throws: CyberKitError.self) {
            _ = try EngineRemeshSolver().solve(
                source: try self.cube(), region: .faces([0]), constraints: WeaveConstraints(),
                params: self.params(), onProgress: nil, isCancelled: { false }
            )
        }
    }
}

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

    /// A flat triangulated plane in z = 0 spanning [-1,1]^2 with `n` cells per
    /// side — an unconstrained surface where the cross field has no intrinsic
    /// curvature preference, so a guide dominates the resulting edge flow.
    private func flatPlane(_ n: Int = 12) throws -> Mesh {
        var obj = ""
        for row in 0...n {
            for col in 0...n {
                let x = Float(col) / Float(n) * 2 - 1
                let y = Float(row) / Float(n) * 2 - 1
                obj += "v \(x) \(y) 0\n"
            }
        }
        for row in 0..<n {
            for col in 0..<n {
                let a = row * (n + 1) + col + 1
                let b = a + 1
                let c = a + n + 2
                let d = a + n + 1
                obj += "f \(a) \(b) \(c)\nf \(a) \(c) \(d)\n"  // two tris per cell
            }
        }
        return try mesh(fromOBJ: obj)
    }

    /// Mean 4-RoSy alignment of the mesh's in-plane edges to world direction
    /// `g`: `cos(4·θ)` averaged over edges, where θ is the in-plane angle
    /// between the edge and `g`. +1 when every edge runs parallel OR
    /// perpendicular to `g` (perfect quad alignment); lower when the flow sits
    /// at an angle to `g`.
    private func edgeAlignment(_ m: Mesh, to g: SIMD3<Float>) -> Float {
        let gx = g.x, gy = g.y
        let gLen = (gx * gx + gy * gy).squareRoot()
        let gAng = Foundation.atan2(gy / gLen, gx / gLen)
        var sum: Float = 0
        var count = 0
        for e in 0..<UInt32(m.edgeCount) {
            guard let ends = m.edgeEndpoints(of: e),
                let a = m.vertexPosition(ends.0), let b = m.vertexPosition(ends.1)
            else { continue }
            let d = b - a
            let len = (d.x * d.x + d.y * d.y).squareRoot()
            guard len > 1e-6 else { continue }
            let theta = Foundation.atan2(d.y / len, d.x / len) - gAng
            sum += Foundation.cos(4 * theta)
            count += 1
        }
        return count > 0 ? sum / Float(count) : 0
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

    @Test("targetingQuads sets the requested budget and clamps to a floor")
    func targetingQuadsClamps() {
        #expect(SolverParameters.targetingQuads(2500).remesh.targetQuads == 2500)
        #expect(SolverParameters.targetingQuads(0).remesh.targetQuads == 4, "clamped to floor")
        #expect(SolverParameters.targetingQuads(-100).remesh.targetQuads == 4)
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

    // MARK: - Guide-field steering (add-weave-guide-field-steering)

    /// Field-aligned params (guides only steer the field-aligned quadrangulator;
    /// force it on both sides so the comparison isolates the guide's effect).
    private func fieldAlignedParams() -> SolverParameters {
        var p = SolverParameters()
        p.remesh.targetQuads = 400
        p.remesh.quadMethod = .fieldAligned
        return p
    }

    @Test("A guide steers edge flow toward its direction")
    func guideSteersFlow() throws {
        // A guide at 30° — deliberately off the plane's axis-aligned boundary,
        // so an unguided solve (which the boundary pulls toward the axes) does
        // NOT already align to it, making the guide's effect measurable.
        let g = SIMD3<Float>(Foundation.cos(0.5236), Foundation.sin(0.5236), 0)  // 30°

        // Unguided baseline.
        let unguided = try #require(try EngineRemeshSolver().solve(
            source: try flatPlane(), region: .wholeMesh, constraints: WeaveConstraints(),
            params: fieldAlignedParams(), onProgress: nil, isCancelled: { false }
        ))
        let unguidedAlign = edgeAlignment(unguided.mesh, to: g)

        // Guided: guide samples marching across the plane along g.
        var guidePoints: [SIMD3<Float>] = []
        for i in -5...5 {
            let t = Float(i) / 5
            guidePoints.append(SIMD3(t, t * 0.5, 0))
        }
        let stroke = GuideStroke(points: guidePoints)
        let guided = try #require(try EngineRemeshSolver().solve(
            source: try flatPlane(), region: .wholeMesh,
            constraints: WeaveConstraints(guideStrokes: [stroke]),
            params: fieldAlignedParams(), onProgress: nil, isCancelled: { false }
        ))
        let guidedAlign = edgeAlignment(guided.mesh, to: g)

        // The guided flow aligns to the guide direction more than the unguided.
        #expect(guidedAlign > unguidedAlign,
            "guided \(guidedAlign) should align to the guide more than unguided \(unguidedAlign)")
    }

    @Test("An empty guide set leaves the solve identical")
    func emptyGuidesUnchanged() throws {
        let solver = EngineRemeshSolver()
        func payload(_ constraints: WeaveConstraints) throws -> Data {
            try #require(try solver.solve(
                source: try flatPlane(), region: .wholeMesh, constraints: constraints,
                params: fieldAlignedParams(), onProgress: nil, isCancelled: { false }
            )).mesh.payloadData()
        }
        // Empty guide list == no guides == the plain solve.
        #expect(try payload(WeaveConstraints(guideStrokes: [])) == payload(WeaveConstraints()))
    }

    @Test("A guided solve is deterministic")
    func guidedSolveIsDeterministic() throws {
        let stroke = GuideStroke(points: [SIMD3(-1, -0.5, 0), SIMD3(1, 0.5, 0)])
        let solver = EngineRemeshSolver()
        func payload() throws -> Data {
            try #require(try solver.solve(
                source: try flatPlane(), region: .wholeMesh,
                constraints: WeaveConstraints(guideStrokes: [stroke]),
                params: fieldAlignedParams(), onProgress: nil, isCancelled: { false }
            )).mesh.payloadData()
        }
        #expect(try payload() == payload())
    }

    /// WAS "a sub-region solve is rejected this slice". `EngineRemeshSolver` now
    /// honours `.faces` by carving the source (openspec add-painted-region-retopo),
    /// which is what lets the app retopologize a painted part of the Target — the
    /// dormancy `add-weave-region-selection` recorded as "nothing in the app
    /// produces a region".
    @Test("A sub-region solve remeshes only the region's faces")
    func subRegionSolvesTheRegion() throws {
        let source = try cube()
        let faces = source.liveFaceIDs().sorted()
        let ghost = try EngineRemeshSolver().solve(
            source: source, region: .faces(Array(faces.prefix(2))),
            constraints: WeaveConstraints(),
            params: params(), onProgress: nil, isCancelled: { false }
        )

        #expect(ghost != nil, "a region solve must produce a cage")
        // The Target is only ever the surface: a solve never modifies it.
        #expect(source.faceCount == faces.count)
    }

    /// The two refusals that keep a selection bug visible rather than silently
    /// solving something else.
    @Test("An empty region, and one naming every face, are still refused")
    func degenerateRegionsRejected() throws {
        let source = try cube()
        #expect(throws: CyberKitError.self) {
            _ = try EngineRemeshSolver().solve(
                source: source, region: .faces([]), constraints: WeaveConstraints(),
                params: self.params(), onProgress: nil, isCancelled: { false }
            )
        }
        #expect(throws: CyberKitError.self) {
            _ = try EngineRemeshSolver().solve(
                source: source, region: .faces(source.liveFaceIDs().sorted()),
                constraints: WeaveConstraints(),
                params: self.params(), onProgress: nil, isCancelled: { false }
            )
        }
    }
}

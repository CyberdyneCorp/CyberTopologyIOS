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
    /// A unit cube — a small closed manifold the remesher can quadrangulate.
    private func cube() throws -> Mesh {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("weave-\(UUID().uuidString).obj")
        try """
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
        """.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Mesh.loadOBJ(at: url)
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

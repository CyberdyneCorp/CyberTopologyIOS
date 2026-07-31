import CyberKit
import Foundation
import Testing
import simd

/// The rigid multi-vertex move behind loop-scope Move (openspec
/// add-context-aware-move; spec: pencil-interaction / "An edge loop moves
/// rigidly").
///
/// Public-API + inline OBJ fixtures, so this suite runs on DEVICE too
/// (mirrored into the app-hosted target in project.yml).
@Suite("Move vertices ops")
struct MoveVerticesOpsTests {
    private func mesh(fromOBJ text: String) throws -> Mesh {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("movev-\(UUID().uuidString).obj")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Mesh.loadOBJ(at: url)
    }

    /// A `cells` x `cells` quad grid on z = 0 with unit cells.
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

    @Test("every listed vertex takes the same displacement")
    func movesRigidly() throws {
        let m = try grid(cells: 2)
        let ids = m.liveVertexIDs().sorted()
        let before = ids.compactMap { m.vertexPosition($0) }
        let moved = [ids[0], ids[1]]

        let count = try m.moveVertices(moved, by: SIMD3(0.5, 0, 0))

        #expect(count == 2)
        for (index, id) in ids.enumerated() {
            let now = try #require(m.vertexPosition(id))
            let expected =
                moved.contains(id) ? before[index] + SIMD3(0.5, 0, 0) : before[index]
            #expect(simd_distance(now, expected) < 1e-5, "vertex \(id) at \(now)")
        }
    }

    /// The property that makes a loop worth dragging: it is still the same loop
    /// afterwards.
    @Test("the moved set keeps its shape")
    func preservesShape() throws {
        let m = try grid(cells: 3)
        // One column of the grid: x = 0 at every y.
        // Sorted along the column, so "adjacent" means geometrically adjacent.
        let column = m.liveVertexIDs()
            .filter { (m.vertexPosition($0)?.x).map { abs($0) < 1e-5 } ?? false }
            .sorted { (m.vertexPosition($0)?.y ?? 0) < (m.vertexPosition($1)?.y ?? 0) }
        #expect(column.count == 4)
        let spacingBefore = spacings(of: column, in: m)

        try m.moveVertices(column, by: SIMD3(0, 0, 0.75))

        #expect(spacings(of: column, in: m) == spacingBefore)
    }

    private func spacings(of vertices: [UInt32], in mesh: Mesh) -> [Float] {
        zip(vertices, vertices.dropFirst()).compactMap { a, b in
            guard let pa = mesh.vertexPosition(a), let pb = mesh.vertexPosition(b) else {
                return nil
            }
            return (simd_distance(pa, pb) * 1000).rounded() / 1000
        }
    }

    @Test("a pinned vertex does not move, and the rest still do")
    func pinnedVerticesHold() throws {
        let m = try grid(cells: 2)
        let ids = m.liveVertexIDs().sorted()
        let pinned = ids[0]
        let pinnedBefore = try #require(m.vertexPosition(pinned))
        let freeBefore = try #require(m.vertexPosition(ids[1]))

        let count = try m.moveVertices(
            [ids[0], ids[1]], by: SIMD3(1, 0, 0), pinned: [pinned]
        )

        #expect(count == 1, "the pinned vertex must not be counted as moved")
        #expect(m.vertexPosition(pinned) == pinnedBefore)
        let free = try #require(m.vertexPosition(ids[1]))
        #expect(simd_distance(free, freeBefore + SIMD3(1, 0, 0)) < 1e-5)
    }

    @Test("dead ids are skipped, not thrown on")
    func deadIDsAreSkipped() throws {
        let m = try grid(cells: 2)
        let live = m.liveVertexIDs().sorted()
        let dead = UInt32(m.vertexCapacity + 10)

        let count = try m.moveVertices([live[0], dead], by: SIMD3(0, 0.25, 0))

        #expect(count == 1)
    }

    @Test("nothing to move is not an error")
    func emptyIsANoOp() throws {
        let m = try grid(cells: 2)
        let before = m.liveVertexIDs().sorted().compactMap { m.vertexPosition($0) }
        #expect(try m.moveVertices([], by: SIMD3(1, 1, 1)) == 0)
        #expect(m.liveVertexIDs().sorted().compactMap { m.vertexPosition($0) } == before)
    }

    /// A moved vertex re-snaps onto the Target, which is what keeps a dragged
    /// loop lying on the surface instead of sliding off it.
    @Test("moved vertices reproject onto the Target")
    func movedVerticesFollowTheTarget() throws {
        // Target: a plane tilted so z = 0.5x — no z = 0 point except at x = 0,
        // so a vertex that did not reproject is trivially detectable.
        let target = try mesh(fromOBJ: """
        v -10 -10 -5
        v 10 -10 5
        v 10 10 5
        v -10 10 -5
        f 1 2 3 4
        """)
        let snapper = try SurfaceSnapper(target: target)
        let m = try grid(cells: 2)
        let ids = m.liveVertexIDs().sorted()

        try m.moveVertices(ids, by: SIMD3(1, 0, 0), snapping: snapper)

        for id in ids {
            let position = try #require(m.vertexPosition(id))
            #expect(
                abs(position.z - position.x * 0.5) < 1e-2,
                "vertex \(id) at \(position) is off the Target plane"
            )
        }
    }

    /// The result must not depend on the order the ids arrive in — positions are
    /// read before anything moves.
    @Test("the order of the ids does not change the result")
    func orderIndependent() throws {
        let forward = try grid(cells: 2)
        let backward = try grid(cells: 2)
        let ids = forward.liveVertexIDs().sorted()

        try forward.moveVertices(ids, by: SIMD3(0.3, -0.2, 0.1))
        try backward.moveVertices(ids.reversed(), by: SIMD3(0.3, -0.2, 0.1))

        for id in ids {
            let a = try #require(forward.vertexPosition(id))
            let b = try #require(backward.vertexPosition(id))
            #expect(simd_distance(a, b) < 1e-6)
        }
    }
}

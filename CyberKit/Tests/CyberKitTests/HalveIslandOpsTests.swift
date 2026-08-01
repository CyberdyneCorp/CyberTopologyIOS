import CyberKit
import Foundation
import Testing
import simd

/// Halving one island of a cage (openspec add-island-scoped-halve).
///
/// REPORTED FROM DEVICE: two patches with one selected, "it should work only on
/// the selected one". Halve is whole-cage because a loop does not stop at a patch
/// boundary — but an island's loops cannot leave it, so there the objection does
/// not apply.
struct HalveIslandOpsTests {
    private func mesh(fromOBJ text: String) throws -> Mesh {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("halve-island-\(UUID().uuidString).obj")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Mesh.loadOBJ(at: url)
    }

    /// `count` separate `cells` x `cells` grids, spaced far apart.
    private func patches(count: Int, cells: Int, spacing: Float = 10) throws -> Mesh {
        var lines: [String] = []
        let side = cells + 1
        for patch in 0..<count {
            let offset = Float(patch) * spacing
            for y in 0...cells {
                for x in 0...cells { lines.append("v \(Float(x) + offset) \(y) 0") }
            }
        }
        for patch in 0..<count {
            let base = patch * side * side
            for y in 0..<cells {
                for x in 0..<cells {
                    let a = base + y * side + x + 1  // 1-based OBJ
                    lines.append("f \(a) \(a + 1) \(a + side + 1) \(a + side)")
                }
            }
        }
        return try mesh(fromOBJ: lines.joined(separator: "\n"))
    }

    /// The faces of the patch each face belongs to, by connectivity.
    private func island(containing seed: UInt32, in mesh: Mesh) -> Set<UInt32> {
        var group: Set<UInt32> = [seed]
        var changed = true
        while changed {
            changed = false
            var vertices: Set<UInt32> = []
            for face in group { vertices.formUnion(mesh.faceVertices(face)) }
            for face in mesh.liveFaceIDs() where !group.contains(face) {
                if mesh.faceVertices(face).contains(where: { vertices.contains($0) }) {
                    group.insert(face)
                    changed = true
                }
            }
        }
        return group
    }

    @Test("one island of a two-patch cage halves; the other is untouched")
    func oneIslandHalves() throws {
        let cage = try patches(count: 2, cells: 4)
        #expect(cage.faceCount == 32, "two 4x4 patches")
        let seed = try #require(cage.liveFaceIDs().sorted().first)
        let selected = island(containing: seed, in: cage)
        #expect(selected.count == 16)
        // Where the OTHER patch's vertices are, before anything happens.
        let otherBefore = Set(
            cage.liveVertexIDs().compactMap { cage.vertexPosition($0) }
                .filter { $0.x > 5 }.map { "\($0.x),\($0.y)" }
        )

        let report = try cage.halveDensity(limitedTo: selected)

        #expect(report.facesBefore == 16, "the ISLAND's own before-count")
        #expect(report.facesAfter == 4, "4x4 -> 2x2")
        #expect(cage.faceCount == 4 + 16, "the halved island plus the untouched patch")
        #expect(try cage.stats().quads == cage.faceCount, "still quad-only")
        // The untouched patch is bit-for-bit where it was.
        let otherAfter = Set(
            cage.liveVertexIDs().compactMap { cage.vertexPosition($0) }
                .filter { $0.x > 5 }.map { "\($0.x),\($0.y)" }
        )
        #expect(otherAfter == otherBefore, "the unselected patch must not move")
    }

    /// The whole point of the restriction: a selection ATTACHED to the rest of the
    /// cage has loops running past it, so it is refused rather than half-halved.
    @Test("a selection attached to the rest of the cage is refused")
    func anAttachedSelectionIsRefused() throws {
        let cage = try patches(count: 1, cells: 4)
        let faces = cage.faceCount
        // Half of one patch: attached along its middle.
        let half = Set(cage.liveFaceIDs().sorted().prefix(8))

        #expect(!cage.isSelfContainedIsland(half))
        #expect(throws: Mesh.IslandFailure.notAnIsland) {
            try cage.halveDensity(limitedTo: half)
        }
        #expect(cage.faceCount == faces, "a refusal leaves the cage untouched")
    }

    /// Vertex-touching counts as attached. Two patches meeting at a single corner
    /// share no EDGE, so an edge-based test would call this an island — and the
    /// splice would then duplicate that corner and tear them apart.
    @Test("patches meeting at one vertex are not an island")
    func aSharedCornerIsNotAnIsland() throws {
        let cage = try mesh(fromOBJ: """
        v 0 0 0
        v 1 0 0
        v 1 1 0
        v 0 1 0
        v 2 1 0
        v 2 2 0
        v 1 2 0
        f 1 2 3 4
        f 3 5 6 7
        """)
        let first = try #require(cage.liveFaceIDs().sorted().first)

        #expect(
            !cage.isSelfContainedIsland([first]),
            "they share vertex 3, so splicing would duplicate it"
        )
    }

    /// An island still has to satisfy every rule a whole cage does.
    @Test("an island that is not halvable refuses for its own reason")
    func anIslandKeepsTheOrdinaryRules() throws {
        let cage = try patches(count: 2, cells: 3)  // 3x3: odd in both directions
        let seed = try #require(cage.liveFaceIDs().sorted().first)
        let selected = island(containing: seed, in: cage)
        let faces = cage.faceCount

        #expect(throws: Mesh.HalveDensityFailure.oddCellCount) {
            try cage.halveDensity(limitedTo: selected)
        }
        #expect(cage.faceCount == faces, "and the cage is untouched")
    }

    /// Subdividing an island is sound for the reason the whole-cage restriction
    /// exists: a subdivided patch splits the edges it SHARES with its neighbours,
    /// and an island shares none.
    @Test("one island of a two-patch cage subdivides; the other is untouched")
    func oneIslandSubdivides() throws {
        let cage = try patches(count: 2, cells: 2)
        #expect(cage.faceCount == 8, "two 2x2 patches")
        let seed = try #require(cage.liveFaceIDs().sorted().first)
        let selected = island(containing: seed, in: cage)
        #expect(selected.count == 4)
        let otherBefore = Set(
            cage.liveVertexIDs().compactMap { cage.vertexPosition($0) }
                .filter { $0.x > 5 }.map { "\($0.x),\($0.y)" }
        )

        try cage.subdivide(limitedTo: selected)

        #expect(cage.faceCount == 16 + 4, "the island quadrupled, the other untouched")
        #expect(try cage.stats().quads == cage.faceCount, "subdivision yields quads")
        let otherAfter = Set(
            cage.liveVertexIDs().compactMap { cage.vertexPosition($0) }
                .filter { $0.x > 5 }.map { "\($0.x),\($0.y)" }
        )
        #expect(otherAfter == otherBefore, "the unselected patch must not move")
    }

    @Test("an attached selection cannot be subdivided alone either")
    func anAttachedSelectionCannotSubdivide() throws {
        let cage = try patches(count: 1, cells: 4)
        let faces = cage.faceCount
        let half = Set(cage.liveFaceIDs().sorted().prefix(8))

        #expect(throws: Mesh.IslandFailure.notAnIsland) {
            try cage.subdivide(limitedTo: half)
        }
        #expect(cage.faceCount == faces, "a refusal leaves the cage untouched")
    }

    @Test("an empty selection is refused")
    func anEmptySelectionIsRefused() throws {
        let cage = try patches(count: 1, cells: 4)
        #expect(throws: Mesh.IslandFailure.emptySelection) {
            try cage.halveDensity(limitedTo: [])
        }
    }

    /// Selecting EVERY face of a one-patch cage is an island — the whole cage —
    /// and must behave exactly like the unscoped halve.
    @Test("selecting the whole cage matches the unscoped halve")
    func theWholeCageIsAnIsland() throws {
        let scoped = try patches(count: 1, cells: 4)
        let unscoped = try patches(count: 1, cells: 4)

        let a = try scoped.halveDensity(limitedTo: Set(scoped.liveFaceIDs()))
        let b = try unscoped.halveDensity()

        #expect(a.facesAfter == b.facesAfter)
        #expect(scoped.faceCount == unscoped.faceCount)
        #expect(
            Set(scoped.liveVertexIDs().compactMap { scoped.vertexPosition($0) }.map(\.x))
                == Set(unscoped.liveVertexIDs().compactMap { unscoped.vertexPosition($0) }.map(\.x))
        )
    }
}

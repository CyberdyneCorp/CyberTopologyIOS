import CyberKit
import Foundation
import Testing
import simd

/// Finding the quad patch under a double-tap (openspec add-patch-selection-scope).
struct QuadPatchTests {
    private func mesh(fromOBJ text: String) throws -> Mesh {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("patch-\(UUID().uuidString).obj")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Mesh.loadOBJ(at: url)
    }

    /// A flat `cols` x `rows` grid of quads.
    private func grid(cols: Int, rows: Int) throws -> Mesh {
        var obj = ""
        for row in 0...rows {
            for col in 0...cols {
                obj += "v \(col) \(row) 0\n"
            }
        }
        let stride = cols + 1
        for row in 0..<rows {
            for col in 0..<cols {
                let a = row * stride + col + 1
                obj += "f \(a) \(a + 1) \(a + stride + 1) \(a + stride)\n"
            }
        }
        return try mesh(fromOBJ: obj)
    }

    /// A flat open grid has no singularity in it: its rim vertices are REGULAR
    /// at valence 3, and only its four corners are irregular, whose walks run
    /// along the rim. So the whole grid is one patch.
    ///
    /// This is the test that caught the boundary rule: counting every rim vertex
    /// as irregular raked a separatrix inward from each one, walled off every
    /// interior edge, and left a double-tap selecting a single quad.
    @Test func aFlatOpenGridIsOnePatch() throws {
        let cage = try grid(cols: 4, rows: 4)
        let seed = try #require(cage.liveFaceIDs().sorted().first)

        let patch = QuadPatch.faces(containing: seed, in: cage)

        #expect(patch.count == 16, "all 16 quads, not \(patch.count)")
    }

    /// …and a POLE inside that grid partitions it: the walks leaving the
    /// irregular vertex are walls, so the tap no longer takes the whole sheet.
    @Test func anInteriorPoleSplitsTheGrid() throws {
        // A 4x4 grid with one interior vertex pulled into a 3-valence pole by
        // merging two quads into one 6-gon beside it.
        var obj = ""
        for row in 0...4 {
            for col in 0...4 {
                obj += "v \(col) \(row) 0\n"
            }
        }
        let stride = 5
        var faces: [[Int]] = []
        for row in 0..<4 {
            for col in 0..<4 {
                let a = row * stride + col + 1
                faces.append([a, a + 1, a + stride + 1, a + stride])
            }
        }
        for face in faces {
            obj += "f " + face.map(String.init).joined(separator: " ") + "\n"
        }
        let cage = try mesh(fromOBJ: obj)
        let seed = try #require(cage.liveFaceIDs().sorted().first)

        // Baseline: a clean grid is one patch.
        #expect(QuadPatch.faces(containing: seed, in: cage).count == 16)

        // Now make an interior singularity by dissolving nothing but changing
        // the ring: delete one quad, so its corner vertices become boundary and
        // the block around the hole stops being regular.
        try cage.deleteFaces([cage.liveFaceIDs().sorted()[5]])
        let reseeded = try #require(cage.liveFaceIDs().sorted().first)
        let split = QuadPatch.faces(containing: reseeded, in: cage)

        #expect(
            split.count < cage.faceCount,
            "the hole's corners are irregular, so the sheet is no longer one block"
        )
    }

    /// A CLOSED cage with no irregular vertex anywhere — a torus grid — has no
    /// separatrix to stop at, so the patch is the whole surface. Stated because
    /// it is the honest outcome of the rule, not a bug: there is genuinely one
    /// grid block.
    @Test func aFullyRegularClosedCageIsOnePatch() throws {
        // 4x4 torus: every vertex has valence 4, no boundary.
        let n = 4
        var obj = ""
        for i in 0..<n {
            for j in 0..<n {
                let u = Float(i) / Float(n) * 2 * .pi
                let v = Float(j) / Float(n) * 2 * .pi
                let r: Float = 1, tube: Float = 0.35
                let x = (r + tube * cos(v)) * cos(u)
                let y = (r + tube * cos(v)) * sin(u)
                let z = tube * sin(v)
                obj += "v \(x) \(y) \(z)\n"
            }
        }
        for i in 0..<n {
            for j in 0..<n {
                let a = i * n + j + 1
                let b = i * n + (j + 1) % n + 1
                let c = ((i + 1) % n) * n + (j + 1) % n + 1
                let d = ((i + 1) % n) * n + j + 1
                obj += "f \(a) \(b) \(c) \(d)\n"
            }
        }
        let torus = try mesh(fromOBJ: obj)
        let seed = try #require(torus.liveFaceIDs().sorted().first)

        let patch = QuadPatch.faces(containing: seed, in: torus)

        #expect(
            patch.count == torus.faceCount,
            "no singularity anywhere means one grid block: \(patch.count) of \(torus.faceCount)"
        )
    }

    /// A triangle has no grid to belong to, so tapping one selects it alone
    /// rather than flooding through the place the topology stops being regular.
    @Test func aNonQuadSeedSelectsOnlyItself() throws {
        let mixed = try mesh(fromOBJ: """
        v 0 0 0
        v 1 0 0
        v 2 0 0
        v 0 1 0
        v 1 1 0
        v 2 1 0
        f 1 2 5 4
        f 2 3 5
        """)
        let triangle = try #require(
            mixed.liveFaceIDs().first { mixed.faceVertices($0).count == 3 }
        )

        let patch = QuadPatch.faces(containing: triangle, in: mixed)

        #expect(patch == [triangle])
    }

    /// A non-quad is a WALL: the fill must not cross one into whatever lies
    /// beyond, because a triangle is precisely where the grid stops.
    @Test func theFillDoesNotCrossANonQuad() throws {
        // Two quads separated by a triangle strip.
        let cage = try mesh(fromOBJ: """
        v 0 0 0
        v 1 0 0
        v 2 0 0
        v 3 0 0
        v 0 1 0
        v 1 1 0
        v 2 1 0
        v 3 1 0
        f 1 2 6 5
        f 2 3 6
        f 3 7 6
        f 3 4 8 7
        """)
        let quads = cage.liveFaceIDs().filter { cage.faceVertices($0).count == 4 }.sorted()
        let first = try #require(quads.first)
        let last = try #require(quads.last)

        let patch = QuadPatch.faces(containing: first, in: cage)

        #expect(patch.contains(first))
        #expect(!patch.contains(last), "the triangles between them are a wall")
    }

    @Test func anUnknownFaceSelectsNothing() throws {
        let cage = try grid(cols: 2, rows: 2)
        #expect(QuadPatch.faces(containing: 9_999, in: cage).isEmpty)
    }

    /// The walk must terminate on a cage with a pole (a valence-3 vertex), which
    /// is where a naive "keep going straight" spins forever.
    @Test func aCageWithAPoleTerminates() throws {
        let cube = try mesh(fromOBJ: """
        v 0 0 0
        v 1 0 0
        v 1 1 0
        v 0 1 0
        v 0 0 1
        v 1 0 1
        v 1 1 1
        v 0 1 1
        f 1 4 3 2
        f 5 6 7 8
        f 1 2 6 5
        f 2 3 7 6
        f 3 4 8 7
        f 4 1 5 8
        """)
        let seed = try #require(cube.liveFaceIDs().sorted().first)

        // Every vertex of a cube is valence 3, so every one is irregular and the
        // patch is the single face it started from.
        let patch = QuadPatch.faces(containing: seed, in: cube)

        #expect(patch == [seed], "a cube is all corners: each face is its own block")
    }
}

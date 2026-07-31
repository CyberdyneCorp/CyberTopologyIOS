import CyberKit
import CyberKitTesting
import Foundation
import Testing
import simd

/// Vertices belonging to no face (openspec fix-faceless-cage-vertices).
///
/// REPORTED FROM DEVICE as "why can't I Relax this part of the bunny ears?".
/// Measured cause: a whole-mesh solve returned a 1108-face cage carrying 1186
/// vertices, 91 of them in no face at all and 41% of those in the ears. The
/// engine's Relax builds a vertex's one-ring from its edges, so it skips them
/// silently — 130 relax passes over the ear tip moved zero of the 15 vertices
/// under the brush, while the same relax unmasked moved 1084 of 1186.
struct FacelessVertexPruneTests {
    private func mesh(fromOBJ text: String) throws -> Mesh {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("prune-\(UUID().uuidString).obj")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Mesh.loadOBJ(at: url)
    }

    /// A grid plus one vertex no face references.
    private func gridWithStrayVertex() throws -> Mesh {
        var obj = ""
        for row in 0...2 {
            for col in 0...2 {
                obj += "v \(col) \(row) 0\n"
            }
        }
        obj += "v 5 5 0\n"  // the stray: vertex 10, in no face
        for row in 0..<2 {
            for col in 0..<2 {
                let a = row * 3 + col + 1
                obj += "f \(a) \(a + 1) \(a + 4) \(a + 3)\n"
            }
        }
        return try mesh(fromOBJ: obj)
    }

    @Test func aFacelessVertexIsFoundAndDropped() throws {
        let mesh = try gridWithStrayVertex()
        #expect(mesh.vertexCount == 10)
        #expect(mesh.faceCount == 4)
        #expect(mesh.facelessVertexIDs().count == 1, "the stray belongs to no face")

        let (pruned, report) = try mesh.prunedOfFacelessVertices()

        #expect(report.verticesDropped == 1)
        #expect(report.facesSkipped == 0)
        #expect(pruned.vertexCount == 9, "the nine the faces use")
        #expect(pruned.faceCount == 4, "every face survives")
        #expect(pruned.facelessVertexIDs().isEmpty)
    }

    /// The mesh must be otherwise UNCHANGED: a prune that quietly welded or moved
    /// something would be worse than the litter it removes.
    @Test func pruningPreservesTheGeometryItKeeps() throws {
        let mesh = try gridWithStrayVertex()
        let before = Set(
            mesh.liveVertexIDs().compactMap { mesh.vertexPosition($0) }
                .filter { $0 != SIMD3<Float>(5, 5, 0) }
                .map { "\($0.x),\($0.y),\($0.z)" }
        )
        let (pruned, _) = try mesh.prunedOfFacelessVertices()
        let after = Set(
            pruned.liveVertexIDs().compactMap { pruned.vertexPosition($0) }
                .map { "\($0.x),\($0.y),\($0.z)" }
        )
        #expect(after == before, "exact positions, and the sharing that made 9 not 16")
        // Sharing preserved: 4 quads with no sharing would be 16 vertices.
        #expect(pruned.vertexCount == 9)
    }

    @Test func aCleanMeshIsUnaffected() throws {
        let mesh = try mesh(fromOBJ: "v 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nf 1 2 3 4\n")
        let (pruned, report) = try mesh.prunedOfFacelessVertices()
        #expect(!report.droppedAnything)
        #expect(pruned.vertexCount == 4 && pruned.faceCount == 1)
    }

    /// THE REGRESSION, on the mesh that produced the report: a whole-mesh solve
    /// hands back a cage with nothing face-less in it.
    ///
    /// Before the prune this cage carried 91 such vertices out of 1186, 41% of
    /// them in the ears — which is why Relax there did nothing at all.
    @Test func aWholeMeshSolveReturnsNoFacelessVertices() throws {
        let source = try Mesh.loadOBJ(at: MeshFixtureCorpus.stanfordBunnyURL())
        var params = SolverParameters.medium
        params.remesh.targetQuads = 742
        params.remesh.pureQuads = true
        let ghost = try #require(try EngineRemeshSolver().solve(
            source: source, region: .wholeMesh, constraints: WeaveConstraints(),
            params: params, onProgress: nil, isCancelled: { false }
        ))

        #expect(ghost.mesh.faceCount > 0)
        #expect(
            ghost.mesh.facelessVertexIDs().isEmpty,
            "every cage vertex must belong to a face, or Relax cannot touch it"
        )
        // The ghost's own face set still describes the cage it ships.
        #expect(ghost.addedFaces.count == ghost.mesh.faceCount)
    }

    /// WHY the litter persists in a saved document, and so why it has to be
    /// dropped at the source: serializing keeps it. The user's cage read
    /// 820 v · 742 f, where a closed quad cage needs F + 2 = 744.
    @Test func serializingDoesNotDropFacelessVertices() throws {
        let mesh = try gridWithStrayVertex()
        let roundTripped = try Mesh(payloadData: mesh.payloadData())
        #expect(
            roundTripped.facelessVertexIDs().count == 1,
            "a payload round trip preserves it, so nothing downstream cleans up"
        )
    }
}

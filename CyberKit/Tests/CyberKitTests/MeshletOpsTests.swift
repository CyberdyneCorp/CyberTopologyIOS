import CyberKit
import Foundation
import Testing
import simd

/// Meshlet clusters through CyberKit (add-meshlet-target-path, task 3.2).
/// Public-API + inline fixtures, so this suite is device-safe and shared into the
/// app-hosted target to run on the iPad too.
@Suite("Meshlet clusters")
struct MeshletOpsTests {
    private func mesh(fromOBJ text: String) throws -> Mesh {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meshlet-\(UUID().uuidString).obj")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Mesh.loadOBJ(at: url)
    }

    /// A triangulated grid — enough triangles to need several clusters.
    private func grid(_ n: Int) throws -> Mesh {
        var obj = ""
        for y in 0...n {
            for x in 0...n { obj += "v \(x) \(y) 0\n" }
        }
        let stride = n + 1
        for y in 0..<n {
            for x in 0..<n {
                let a = y * stride + x + 1, b = a + 1, c = a + stride + 1, d = a + stride
                obj += "f \(a) \(b) \(c)\n"
                obj += "f \(a) \(c) \(d)\n"
            }
        }
        return try mesh(fromOBJ: obj)
    }

    @Test("The Swift cluster struct mirrors the C layout — the zero-copy precondition")
    func layoutMatchesC() {
        // This is the guard that was missing first time round. The initial version used
        // SIMD3<Float> for the vector members, which is 16 bytes rather than 12, so the
        // struct was 56 bytes against C's 48 and every field after `center` sat at the
        // wrong offset. It compiled fine and read garbage: triangleCount came back as
        // 4,853,069,083 and every radius as 0. A mismatch here is silent, so it is
        // asserted rather than reasoned about.
        #expect(Mesh.meshletLayoutMatchesC)
    }

    @Test("Clusters cover every triangle and index the shared render buffers")
    func clustersCoverAndIndexCorrectly() throws {
        let mesh = try grid(20)  // 800 triangles
        #expect(mesh.meshletCount > 1, "a mesh this size should need several clusters")

        try mesh.withRenderBuffers { render in
            let renderVertices = render.positions.count / 3
            mesh.withMeshletBuffers { clusters in
                #expect(clusters.isDrawable)
                // Every triangle of the render stream is in exactly one cluster.
                #expect(clusters.triangleCount == render.triangleIndices.count / 3)
                let clustered = clusters.meshlets.reduce(0) { $0 + Int($1.triangleCount) }
                #expect(clustered == clusters.triangleCount)

                // Cluster vertex indices address the SAME array the position buffer
                // uses. Out of range here would be a GPU read past the end.
                for index in clusters.vertices {
                    #expect(Int(index) < renderVertices)
                }
                // Local corners stay inside their own cluster's slice.
                for meshlet in clusters.meshlets {
                    for t in 0..<Int(meshlet.triangleCount) {
                        let base = (Int(meshlet.triangleOffset) + t) * 3
                        for c in 0..<3 {
                            #expect(clusters.localIndices[base + c] < UInt8(meshlet.vertexCount))
                        }
                    }
                }
            }
        }
    }

    @Test("Bounding spheres CONTAIN their clusters — culling must never drop a visible one")
    func spheresAreConservative() throws {
        let mesh = try grid(12)
        try mesh.withRenderBuffers { render in
            mesh.withMeshletBuffers { clusters in
                for meshlet in clusters.meshlets {
                    for i in 0..<Int(meshlet.vertexCount) {
                        let v = Int(clusters.vertices[Int(meshlet.vertexOffset) + i])
                        let p = SIMD3<Float>(
                            render.positions[v * 3], render.positions[v * 3 + 1],
                            render.positions[v * 3 + 2]
                        )
                        #expect(simd_length(p - meshlet.center) <= meshlet.radius + 1e-4)
                    }
                }
            }
        }
    }

    @Test("A flat mesh yields tight, cullable cones")
    func flatMeshHasTightCones() throws {
        // Every normal identical, so the cone should be maximally tight — this is
        // what makes backface rejection worth doing at all.
        let mesh = try grid(8)
        mesh.withMeshletBuffers { clusters in
            #expect(!clusters.meshlets.isEmpty)
            for meshlet in clusters.meshlets {
                #expect(meshlet.isBackfaceCullable)
                #expect(meshlet.coneCutoff > 0.99)
            }
        }
    }

    @Test("A back-to-back pair declares itself uncullable rather than claiming a cone")
    func foldedClusterFailsSafe() throws {
        let mesh = try self.mesh(fromOBJ: """
        v 0 0 0
        v 1 0 0
        v 0 1 0
        f 1 2 3
        f 1 3 2
        """)
        mesh.withMeshletBuffers { clusters in
            #expect(clusters.meshlets.count == 1)
            let meshlet = clusters.meshlets[0]
            #expect(meshlet.triangleCount == 2)
            // Never cull: no view direction sees only back faces here.
            #expect(meshlet.coneCutoff == 0)
            #expect(!meshlet.isBackfaceCullable)
        }
    }

    @Test("An empty mesh has no clusters and is not drawable")
    func emptyMeshHasNoClusters() throws {
        let mesh = try Mesh()
        #expect(mesh.meshletCount == 0)
        mesh.withMeshletBuffers { clusters in
            #expect(!clusters.isDrawable)
            #expect(clusters.triangleCount == 0)
        }
    }

    @Test("Clusters are rebuilt after an edit, never served stale")
    func clustersInvalidateOnEdit() throws {
        // The compacted vertex ORDER moves on mutation, so a stale cluster would
        // index the wrong vertices — silently drawing scrambled geometry.
        let mesh = try grid(10)
        let before = mesh.meshletCount
        let trianglesBefore = mesh.withMeshletBuffers { $0.triangleCount }
        #expect(before > 0)

        _ = try mesh.deleteFaces([0])

        let trianglesAfter = mesh.withMeshletBuffers { $0.triangleCount }
        #expect(trianglesAfter < trianglesBefore, "clusters must reflect the edit")
        try mesh.withRenderBuffers { render in
            #expect(trianglesAfter == render.triangleIndices.count / 3)
        }
    }
}

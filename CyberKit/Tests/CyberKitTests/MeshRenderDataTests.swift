import CyberRemesherC
import CyberKitTesting
import Foundation
import Testing
@testable import CyberKit

/// Render-data accessors for the Metal viewport (design D2 prerequisite for
/// tasks 2.2–2.4): engine-side triangulation, per-vertex normals and colors,
/// and the zero-copy `withRenderBuffers` views. All expectations run against
/// the real engine on the committed fixtures — no mocks.
@Suite("Mesh render data")
struct MeshRenderDataTests {
    private func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(
            forResource: name, withExtension: "obj", subdirectory: "Fixtures"
        ))
    }

    private var goldensDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Goldens", isDirectory: true)
    }

    /// The colored cube's 6 quads, fan-triangulated deterministically by the
    /// engine around each face's first corner, in file face order.
    private static let expectedCubeIndices: [UInt32] = [
        0, 3, 2, /**/ 0, 2, 1,  // f 1 4 3 2
        4, 5, 6, /**/ 4, 6, 7,  // f 5 6 7 8
        0, 1, 5, /**/ 0, 5, 4,  // f 1 2 6 5
        1, 2, 6, /**/ 1, 6, 5,  // f 2 3 7 6
        2, 3, 7, /**/ 2, 7, 6,  // f 3 4 8 7
        3, 0, 4, /**/ 3, 4, 7,  // f 4 1 5 8
    ]

    // MARK: - Triangulated indices

    @Test("6 cube quads triangulate to 12 triangles / 36 valid indices")
    func cubeTriangulation() throws {
        let mesh = try Mesh.loadOBJ(at: fixture("cube_colored"))
        #expect(mesh.triangleCount == 12)

        let indices = mesh.triangleIndices()
        #expect(indices.count == 36)
        #expect(indices.allSatisfy { $0 < UInt32(mesh.vertexCount) })
        #expect(indices == Self.expectedCubeIndices)
    }

    @Test("colored-cube index buffer is bit-stable (golden)")
    func cubeIndicesGolden() throws {
        let mesh = try Mesh.loadOBJ(at: fixture("cube_colored"))
        var data = Data(capacity: mesh.triangleIndices().count * 4)
        for index in mesh.triangleIndices() {
            withUnsafeBytes(of: index.littleEndian) { data.append(contentsOf: $0) }
        }
        try GoldenFile.compare(
            data,
            golden: goldensDirectory.appendingPathComponent("cube_colored.triangle_indices.golden")
        )
    }

    // MARK: - Normals

    @Test("cube normals are engine-computed, per-vertex, unit length")
    func cubeNormals() throws {
        let mesh = try Mesh.loadOBJ(at: fixture("cube_colored"))
        let normals = mesh.normals()
        #expect(normals.count == mesh.vertexCount * 3)

        // Every cube corner averages three axis-aligned face normals, so
        // each unit normal is (±1,±1,±1)/√3 — check unit length and the
        // exact component magnitude.
        let component = 1.0 / Float(3).squareRoot()
        for base in stride(from: 0, to: normals.count, by: 3) {
            let (x, y, z) = (normals[base], normals[base + 1], normals[base + 2])
            #expect(abs((x * x + y * y + z * z).squareRoot() - 1) < 1e-4)
            #expect(abs(abs(x) - component) < 1e-4)
            #expect(abs(abs(y) - component) < 1e-4)
            #expect(abs(abs(z) - component) < 1e-4)
        }
    }

    @Test("imported per-corner normals are averaged instead of recomputed")
    func importedNormalsWin() throws {
        // A single triangle whose stored normal (0,0,-1) is the OPPOSITE of
        // its geometric winding normal (0,0,1): only the stored-normal path
        // can produce -1.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeshRenderDataTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let obj = directory.appendingPathComponent("tri.obj")
        try """
        v 0 0 0
        v 1 0 0
        v 0 1 0
        vn 0 0 -1
        f 1//1 2//1 3//1
        """.write(to: obj, atomically: true, encoding: .utf8)

        let mesh = try Mesh.loadOBJ(at: obj)
        #expect(mesh.triangleCount == 1)
        #expect(mesh.triangleIndices() == [0, 1, 2])
        #expect(mesh.normals() == [0, 0, -1, 0, 0, -1, 0, 0, -1])
    }

    // MARK: - Colors

    @Test("colored cube exposes the fixture's 8 RGB values exactly")
    func cubeColors() throws {
        let mesh = try Mesh.loadOBJ(at: fixture("cube_colored"))
        #expect(mesh.hasColors)
        let colors = try #require(mesh.colors())
        #expect(colors == [
            1.0, 0.0, 0.0,
            0.0, 1.0, 0.0,
            0.0, 0.0, 1.0,
            1.0, 1.0, 0.0,
            1.0, 0.0, 1.0,
            0.0, 1.0, 1.0,
            1.0, 1.0, 1.0,
            0.25, 0.5, 0.75,
        ])
    }

    @Test("uncolored cube reports no colors")
    func uncoloredCube() throws {
        let mesh = try Mesh.loadOBJ(at: fixture("cube"))
        #expect(!mesh.hasColors)
        #expect(mesh.colors() == nil)
        // The rest of the render data is still available.
        #expect(mesh.triangleCount == 12)
        #expect(mesh.normals().count == mesh.vertexCount * 3)
    }

    // MARK: - Wireframe edges (task 2.3 overlay)

    @Test("cube exposes its 12 authored edges — no fan diagonals")
    func cubeEdges() throws {
        let mesh = try Mesh.loadOBJ(at: fixture("cube_colored"))
        #expect(mesh.edgeCount == 12)

        let edges = mesh.edgeIndices()
        #expect(edges.count == 24)
        #expect(edges.allSatisfy { $0 < UInt32(mesh.vertexCount) })

        // Undirected edge set: exactly the cube's 12 topological edges;
        // shared edges are deduplicated and no triangulation diagonal
        // (e.g. 0-2 from face "f 1 4 3 2") leaks in.
        var seen = Set<[UInt32]>()
        for pair in stride(from: 0, to: edges.count, by: 2) {
            seen.insert([edges[pair], edges[pair + 1]].sorted())
        }
        #expect(seen.count == 12)
        #expect(!seen.contains([0, 2]))
        #expect(seen.contains([0, 1]))
        #expect(seen.contains([0, 3]))
    }

    @Test("edge order is deterministic across handles")
    func edgeDeterminism() throws {
        let first = try Mesh.loadOBJ(at: fixture("cube_colored")).edgeIndices()
        let second = try Mesh.loadOBJ(at: fixture("cube_colored")).edgeIndices()
        #expect(first == second)
    }

    @Test("empty mesh has no edges")
    func emptyMeshEdges() throws {
        let mesh = try Mesh()
        #expect(mesh.edgeCount == 0)
        #expect(mesh.edgeIndices().isEmpty)
    }

    // MARK: - Zero-copy views

    @Test("withRenderBuffers exposes the same data as the copying accessors")
    func zeroCopyMatchesCopies() throws {
        let mesh = try Mesh.loadOBJ(at: fixture("cube_colored"))
        try mesh.withRenderBuffers { buffers in
            #expect(Array(buffers.positions) == mesh.positions())
            #expect(Array(buffers.triangleIndices) == mesh.triangleIndices())
            #expect(Array(buffers.edgeIndices) == mesh.edgeIndices())
            #expect(Array(buffers.normals) == mesh.normals())
            let colors = try #require(buffers.colors)
            #expect(Array(colors) == mesh.colors())
        }
    }

    @Test("zero-copy pointers are cached and stable across calls")
    func zeroCopyPointerStability() throws {
        let mesh = try Mesh.loadOBJ(at: fixture("cube_colored"))
        let first = mesh.withRenderBuffers { ($0.positions.baseAddress, $0.triangleIndices.baseAddress) }
        let second = mesh.withRenderBuffers { ($0.positions.baseAddress, $0.triangleIndices.baseAddress) }
        #expect(first.0 == second.0)
        #expect(first.1 == second.1)
    }

    @Test("uncolored mesh yields a nil colors view")
    func zeroCopyNilColors() throws {
        let mesh = try Mesh.loadOBJ(at: fixture("cube"))
        mesh.withRenderBuffers { buffers in
            #expect(buffers.colors == nil)
            #expect(buffers.positions.count == 24)
            #expect(buffers.triangleIndices.count == 36)
            #expect(buffers.normals.count == 24)
        }
    }

    @Test("empty mesh yields empty render data everywhere")
    func emptyMesh() throws {
        let mesh = try Mesh()
        #expect(mesh.triangleCount == 0)
        #expect(mesh.triangleIndices().isEmpty)
        #expect(mesh.normals().isEmpty)
        #expect(!mesh.hasColors)
        #expect(mesh.colors() == nil)
        mesh.withRenderBuffers { buffers in
            #expect(buffers.positions.isEmpty)
            #expect(buffers.triangleIndices.isEmpty)
            #expect(buffers.edgeIndices.isEmpty)
            #expect(buffers.normals.isEmpty)
            #expect(buffers.colors == nil)
        }
    }
}

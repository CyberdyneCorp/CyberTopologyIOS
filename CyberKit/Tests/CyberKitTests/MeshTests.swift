import CyberRemesherC
import Foundation
import Testing
@testable import CyberKit

@Suite("Mesh facade")
struct MeshTests {
    private var cubeURL: URL {
        get throws {
            try #require(Bundle.module.url(
                forResource: "cube", withExtension: "obj", subdirectory: "Fixtures"
            ))
        }
    }

    @Test("empty mesh has no geometry")
    func emptyMesh() throws {
        let mesh = try Mesh()
        #expect(mesh.vertexCount == 0)
        #expect(mesh.faceCount == 0)
        #expect(mesh.positions().isEmpty)
    }

    @Test("loading a cube OBJ yields real engine counts, positions, stats")
    func loadCube() throws {
        let mesh = try Mesh.loadOBJ(at: cubeURL)
        #expect(mesh.vertexCount == 8)
        #expect(mesh.faceCount == 6)

        let positions = mesh.positions()
        #expect(positions.count == 8 * 3)
        #expect(positions.allSatisfy { abs($0) == 0.5 })

        let stats = try mesh.stats()
        #expect(stats.vertices == 8)
        #expect(stats.quads == 6)
        #expect(stats.triangles == 0)
        #expect(stats.other == 0)
        #expect(stats.islands == 1)
        #expect(stats.islandsFailed == 0)
    }

    @Test("loading a missing file throws .io with an engine message")
    func loadMissingFile() {
        do {
            _ = try Mesh.loadOBJ(at: URL(fileURLWithPath: "/nonexistent/mesh.obj"))
            Issue.record("expected loadOBJ to throw")
        } catch let error as CyberKitError {
            #expect(error.code == .io)
        } catch {
            Issue.record("expected CyberKitError, got \(error)")
        }
    }

    @Test("OBJ save/load round-trips geometry")
    func saveRoundTrip() throws {
        let mesh = try Mesh.loadOBJ(at: cubeURL)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CyberKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let objURL = directory.appendingPathComponent("cube.obj")
        try mesh.saveOBJ(to: objURL)

        let reloaded = try Mesh.loadOBJ(at: objURL)
        #expect(reloaded.vertexCount == 8)
        #expect(reloaded.faceCount == 6)
    }

    @Test("remeshing the cube runs the real pipeline and produces quads")
    func remeshCube() throws {
        let mesh = try Mesh.loadOBJ(at: cubeURL)
        var parameters = RemeshParameters()
        parameters.targetQuads = 100

        let result = try mesh.remeshed(parameters: parameters)
        let stats = try result.stats()
        #expect(stats.quads > 0)
        #expect(result.vertexCount > 0)
        #expect(result.faceCount > 0)
        // The input mesh is never modified by a remesh.
        #expect(mesh.faceCount == 6)
    }

    @Test("RemeshParameters round-trips the engine defaults")
    func defaultParameters() {
        let parameters = RemeshParameters()
        #expect(parameters.targetQuads > 0)
        #expect(parameters.edgeScale > 0)

        let c = parameters.cParams
        var expected = CyberRemeshParamsMirror()
        #expect(Int(c.targetQuads) == expected.targetQuads)
        expected = CyberRemeshParamsMirror()
        #expect(c.quadMethod == Int32(expected.quadMethod))
    }
}

/// Independent read of the engine defaults so the test does not trust
/// `RemeshParameters.init` for its own expected values.
private struct CyberRemeshParamsMirror {
    var targetQuads: Int
    var quadMethod: Int

    init() {
        var raw = CyberRemeshParams()
        cyber_default_params(&raw)
        targetQuads = Int(raw.targetQuads)
        quadMethod = Int(raw.quadMethod)
    }
}

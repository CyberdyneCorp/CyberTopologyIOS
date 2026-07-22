import Foundation
import Testing
import CyberKitTesting
@testable import CyberKit

/// FBX import through the ufbx→OBJ bridge (task 3.10, spec: scene-pipeline /
/// "Import formats"). The committed fixture is a Blender-exported binary FBX
/// of a 2m cube with distinct per-vertex colors
/// (Fixtures/cube_colored.fbx — see the fixture provenance note in the test
/// below); all expectations run against the real engine, no mocks.
@Suite("FBX import")
struct FBXImportTests {
    private func fixtureURL(_ name: String, extension ext: String = "fbx") throws -> URL {
        try #require(Bundle.module.url(
            forResource: name, withExtension: ext, subdirectory: "Fixtures"
        ))
    }

    private var goldensDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Goldens", isDirectory: true)
    }

    private func scratchFile(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FBXImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }

    // MARK: - Fixture import

    @Test("colored-cube FBX loads through the engine with correct counts")
    func cubeCounts() throws {
        let mesh = try Mesh.loadFBX(at: fixtureURL("cube_colored"))
        #expect(mesh.vertexCount == 8)
        #expect(mesh.faceCount == 6)

        let stats = try mesh.stats()
        #expect(stats.quads == 6)  // quads survive: no forced triangulation
        #expect(stats.triangles == 0)

        // Unit/axis normalization: the 2m Blender cube spans ±1 in meters.
        let positions = mesh.positions()
        #expect(positions.count == 24)
        #expect(positions.allSatisfy { abs(abs($0) - 1) < 1e-5 })
    }

    @Test("bridge OBJ text carries per-vertex colors from the FBX color layer")
    func bridgeCarriesVertexColors() throws {
        let text = try FBXImport.objText(contentsOf: fixtureURL("cube_colored"))
        let vertexLines = text.split(separator: "\n").filter { $0.hasPrefix("v ") }
        #expect(vertexLines.count == 8)
        for line in vertexLines {
            // "v x y z r g b" — positions plus bridged colors.
            #expect(line.split(separator: " ").count == 7, "vertex line lost colors: \(line)")
        }
        let faceLines = text.split(separator: "\n").filter { $0.hasPrefix("f ") }
        #expect(faceLines.count == 6)
        #expect(faceLines.allSatisfy { $0.split(separator: " ").count == 5 })  // quads
    }

    @Test("FBX→OBJ bridge output is byte-deterministic (golden)")
    func bridgeGolden() throws {
        let text = try FBXImport.objText(contentsOf: fixtureURL("cube_colored"))
        try GoldenFile.compare(
            Data(text.utf8),
            golden: goldensDirectory.appendingPathComponent("cube_colored.fbx_bridge.golden")
        )
    }

    // MARK: - Error paths

    @Test("missing file throws an IO error")
    func missingFile() throws {
        let bogus = URL(fileURLWithPath: "/tmp/definitely-missing-\(UUID()).fbx")
        let error = #expect(throws: CyberKitError.self) { try Mesh.loadFBX(at: bogus) }
        #expect(error?.code == .io)
    }

    @Test("garbage bytes throw an IO error with the parser's detail")
    func garbageFile() throws {
        let url = try scratchFile(named: "garbage.fbx")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Data("this is not an FBX file".utf8).write(to: url)

        let error = #expect(throws: CyberKitError.self) { try Mesh.loadFBX(at: url) }
        #expect(error?.code == .io)
        #expect(error?.message.isEmpty == false)
    }

    @Test("node names cannot inject OBJ directives into the bridge text")
    func nodeNameInjection() throws {
        // ufbx preserves embedded newlines in node names (ASCII and
        // binary). Unsanitized, this name would emit "# mesh: evil"
        // followed by an injected "v 9 9 9" line — a phantom vertex that
        // shifts every face index by one.
        let url = try scratchFile(named: "evil.fbx")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ascii = """
        ; FBX 7.3.0 project file
        FBXHeaderExtension:  {
            FBXHeaderVersion: 1003
            FBXVersion: 7300
        }
        Objects:  {
            Geometry: 1000000, "Geometry::quad", "Mesh" {
                Vertices: *12 {
                    a: -1,-1,0, 1,-1,0, 1,1,0, -1,1,0
                }
                PolygonVertexIndex: *4 {
                    a: 0,1,2,-4
                }
            }
            Model: 2000000, "Model::evil
        v 9 9 9", "Mesh" {
            }
        }
        Connections:  {
            C: "OO",1000000,2000000
            C: "OO",2000000,0
        }
        """
        try Data(ascii.utf8).write(to: url)

        let text = try FBXImport.objText(contentsOf: url)
        let lines = text.split(separator: "\n")
        // The newline in the name was neutralized: exactly the quad's 4
        // vertices, no injected "v 9 9 9", and the comment line carries the
        // whole name flattened onto one line.
        #expect(lines.filter { $0.hasPrefix("v ") }.count == 4)
        #expect(!lines.contains("v 9 9 9"))
        #expect(lines.contains("# mesh: evil v 9 9 9"))

        // The engine sees the unshifted indices: 4 vertices, 1 quad.
        let mesh = try Mesh.loadFBX(at: url)
        #expect(mesh.vertexCount == 4)
        #expect(mesh.faceCount == 1)
    }

    @Test("an FBX without mesh geometry throws emptyMesh")
    func meshlessFBX() throws {
        // Minimal ASCII FBX (ufbx parses ASCII too): valid header, no
        // geometry objects.
        let url = try scratchFile(named: "empty.fbx")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ascii = """
        ; FBX 7.3.0 project file
        FBXHeaderExtension:  {
            FBXHeaderVersion: 1003
            FBXVersion: 7300
        }
        Objects:  {
        }
        Connections:  {
        }
        """
        try Data(ascii.utf8).write(to: url)

        let error = #expect(throws: CyberKitError.self) { try Mesh.loadFBX(at: url) }
        #expect(error?.code == .emptyMesh)
    }
}

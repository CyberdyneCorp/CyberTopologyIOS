import Foundation
import Testing
@testable import CyberKit

@Suite("Document OBJ import/export")
struct DocumentIOTests {
    private func fixtureURL(_ name: String) throws -> URL {
        let url = try #require(Bundle.module.url(
            forResource: name, withExtension: "obj", subdirectory: "Fixtures"
        ))
        return url
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentIOTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("import command carries counts and applies as a journaled object")
    func importCommand() throws {
        let bundle = DocumentBundle()
        let command = try bundle.importCommand(
            for: fixtureURL("cube_colored"), name: "cube", role: .editMesh
        )

        guard case .addObject(let object, let payload) = command else {
            Issue.record("expected addObject, got \(command)")
            return
        }
        #expect(object.name == "cube")
        #expect(object.role == .editMesh)
        #expect(object.counts == .init(vertices: 8, faces: 6))
        #expect(!payload.isEmpty)

        var applied = bundle
        command.apply(to: &applied)
        let mesh = try applied.mesh(for: applied.manifest.objects[0])
        #expect(mesh.vertexCount == 8)
        #expect(mesh.faceCount == 6)
    }

    @Test("vertex colors survive the engine payload round-trip")
    func vertexColorsPreserved() throws {
        let bundle = DocumentBundle()
        let command = try bundle.importCommand(
            for: fixtureURL("cube_colored"), name: "cube", role: .target
        )
        guard case .addObject(_, let payload) = command else {
            Issue.record("expected addObject")
            return
        }

        // The payload is the engine's OBJ serialization: its vertex lines
        // must retain the 6-component position+color form.
        let text = try #require(String(data: payload, encoding: .utf8))
        let vertexLines = text.split(separator: "\n").filter { $0.hasPrefix("v ") }
        #expect(vertexLines.count == 8)
        for line in vertexLines {
            let components = line.split(separator: " ").dropFirst()
            #expect(components.count == 6, "vertex line lost colors: \(line)")
        }
    }

    @Test("FBX import dispatches by extension and journals exactly like OBJ")
    func importCommandDispatchesFBX() throws {
        let bundle = DocumentBundle()
        let url = try #require(Bundle.module.url(
            forResource: "cube_colored", withExtension: "fbx", subdirectory: "Fixtures"
        ))
        let command = try bundle.importCommand(for: url, name: "fbx cube", role: .target)

        guard case .addObject(let object, let payload) = command else {
            Issue.record("expected addObject, got \(command)")
            return
        }
        #expect(object.name == "fbx cube")
        #expect(object.role == .target)
        #expect(object.counts == .init(vertices: 8, faces: 6))
        #expect(!payload.isEmpty)

        var applied = bundle
        command.apply(to: &applied)
        let mesh = try applied.mesh(for: applied.manifest.objects[0])
        #expect(mesh.vertexCount == 8)
        #expect(mesh.faceCount == 6)
    }

    @Test("unsupported import extensions are rejected with a typed error")
    func importCommandRejectsUnknownExtension() throws {
        let bundle = DocumentBundle()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mesh-\(UUID()).stl")
        let error = #expect(throws: CyberKitError.self) {
            try bundle.importCommand(for: url, name: "x", role: .target)
        }
        #expect(error?.code == .invalidArgument)
        #expect(error?.message.contains(".stl") == true)
    }

    @Test("imported EditMesh is editable and snaps to the Target")
    func importedEditMeshIsEditableAndSnapsToTarget() throws {
        // Scene-pipeline scenario "Import existing low-poly as EditMesh":
        // import an OBJ as EditMesh into a document with a Target, then run
        // an RT edit whose result must land on the Target surface.
        var bundle = DocumentBundle()
        let url = try fixtureURL("cube_colored")
        try bundle.importCommand(for: url, name: "hi", role: .target).apply(to: &bundle)
        try bundle.importCommand(for: url, name: "lo", role: .editMesh).apply(to: &bundle)

        let target = try bundle.mesh(for: bundle.manifest.objects[0])
        let editMesh = try bundle.mesh(for: bundle.manifest.objects[1])
        let snapper = try SurfaceSnapper(target: target)

        // Tweak a cube corner far off the surface: it must be pulled back
        // onto the Target (the ±0.5 cube ⇒ nearest surface point z = 0.5).
        let vertex = try #require(
            editMesh.nearestVertex(to: SIMD3(-0.5, -0.5, -0.5), maxDistance: 1e-3)
        ).vertex
        try editMesh.tweakVertex(vertex, to: SIMD3(0.2, 0.3, 5), snapping: snapper)
        let moved = try #require(editMesh.vertexPosition(vertex))
        #expect(abs(moved.x - 0.2) < 1e-5)
        #expect(abs(moved.y - 0.3) < 1e-5)
        #expect(abs(moved.z - 0.5) < 1e-5)
    }

    @Test("export writes OBJ with an MTL sibling and mtllib reference")
    func exportWritesOBJAndMTL() throws {
        var bundle = DocumentBundle()
        let command = try bundle.importCommand(
            for: fixtureURL("cube_colored"), name: "hero mesh", role: .editMesh
        )
        command.apply(to: &bundle)

        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let written = try bundle.exportOBJ(object: bundle.manifest.objects[0], to: directory)

        #expect(written.count == 2)
        #expect(written[0].lastPathComponent == "hero mesh.obj")
        #expect(written[1].lastPathComponent == "hero mesh.mtl")
        #expect(FileManager.default.fileExists(atPath: written[1].path))

        let objText = try String(contentsOf: written[0], encoding: .utf8)
        #expect(objText.contains("mtllib hero mesh.mtl"))
        #expect(objText.split(separator: "\n").contains { $0.hasPrefix("v ") })

        // Geometry survives the export: reload and compare counts.
        let reloaded = try Mesh.loadOBJ(at: written[0])
        #expect(reloaded.vertexCount == 8)
        #expect(reloaded.faceCount == 6)
    }

    @Test("export file names are sanitized")
    func exportFilenameSanitization() {
        #expect(DocumentBundle.exportFilename(for: "a/b\\c:d") == "a-b-c-d")
        #expect(DocumentBundle.exportFilename(for: "  ") == "Untitled")
        #expect(DocumentBundle.exportFilename(for: "plain") == "plain")
    }
}

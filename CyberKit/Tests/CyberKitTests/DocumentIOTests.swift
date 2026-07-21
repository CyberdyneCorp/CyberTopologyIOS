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
        let command = try bundle.importCommandForOBJ(
            at: fixtureURL("cube_colored"), name: "cube", role: .editMesh
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
        let command = try bundle.importCommandForOBJ(
            at: fixtureURL("cube_colored"), name: "cube", role: .target
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

    @Test("export writes OBJ with an MTL sibling and mtllib reference")
    func exportWritesOBJAndMTL() throws {
        var bundle = DocumentBundle()
        let command = try bundle.importCommandForOBJ(
            at: fixtureURL("cube_colored"), name: "hero mesh", role: .editMesh
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

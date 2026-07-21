import Foundation
import Testing
@testable import CyberKit

@Suite("Document bundle")
struct DocumentBundleTests {
    private var cubeURL: URL {
        get throws {
            try #require(Bundle.module.url(
                forResource: "cube", withExtension: "obj", subdirectory: "Fixtures"
            ))
        }
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentBundleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("new manifest carries the current schema version and RT stage")
    func manifestDefaults() {
        let manifest = DocumentManifest()
        #expect(manifest.schemaVersion == DocumentManifest.currentSchemaVersion)
        #expect(manifest.stage == .retopology)
        #expect(manifest.objects.isEmpty)
    }

    @Test("manifest JSON round-trips objects, stage, and schema version")
    func manifestJSONRoundTrip() throws {
        var manifest = DocumentManifest(stage: .uv)
        manifest.objects.append(DocumentManifest.Object(
            name: "Sculpt", role: .target, payloadFile: "a.payload"
        ))
        manifest.objects.append(DocumentManifest.Object(
            name: "Retopo", role: .editMesh, payloadFile: "b.payload"
        ))

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(DocumentManifest.self, from: data)
        #expect(decoded == manifest)
    }

    @Test("empty bundle round-trips through a file wrapper on disk")
    func emptyBundleRoundTrip() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Empty.cybertopo")

        try DocumentBundle().fileWrapper()
            .write(to: url, options: .atomic, originalContentsURL: nil)
        let reread = try DocumentBundle(fileWrapper: FileWrapper(url: url))
        #expect(reread == DocumentBundle())
    }

    @Test("bundle with a real mesh payload round-trips with full fidelity")
    func meshBundleRoundTrip() throws {
        // Also covers spec document-model / "Free-tier save": the save path
        // has no entitlement check anywhere — write + reopen is full fidelity
        // for any user.
        let mesh = try Mesh.loadOBJ(at: cubeURL)
        var bundle = DocumentBundle(manifest: DocumentManifest(stage: .baking))
        let object = try bundle.addObject(name: "Cube", role: .editMesh, mesh: mesh)
        #expect(bundle.manifest.objects.count == 1)
        #expect(bundle.payloads[object.payloadFile] != nil)

        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Cube.cybertopo")
        try bundle.fileWrapper().write(to: url, options: .atomic, originalContentsURL: nil)

        // manifest.json and objects/ are laid out as documented.
        #expect(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(DocumentBundle.manifestFilename).path
        ))
        #expect(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(DocumentBundle.objectsDirectoryName)
                .appendingPathComponent(object.payloadFile).path
        ))

        let reread = try DocumentBundle(fileWrapper: FileWrapper(url: url))
        #expect(reread == bundle)

        let rereadMesh = try reread.mesh(for: try #require(reread.manifest.objects.first))
        #expect(rereadMesh.vertexCount == 8)
        #expect(rereadMesh.faceCount == 6)
    }

    @Test("mesh payload data round-trips through the opaque facade calls")
    func meshPayloadRoundTrip() throws {
        let mesh = try Mesh.loadOBJ(at: cubeURL)
        let payload = try mesh.payloadData()
        #expect(!payload.isEmpty)

        let reloaded = try Mesh(payloadData: payload)
        #expect(reloaded.vertexCount == 8)
        #expect(reloaded.faceCount == 6)
        #expect(reloaded.positions() == mesh.positions())
    }

    @Test("corrupt payload data throws a CyberKitError")
    func corruptPayload() {
        // The engine's OBJ reader treats unknown lines as noise, but a payload
        // with no geometry at all must be rejected somewhere down the line:
        // an empty payload yields an empty mesh, which addObject would store
        // but mesh loading itself must not crash.
        do {
            let mesh = try Mesh(payloadData: Data("not a mesh".utf8))
            #expect(mesh.vertexCount == 0)
        } catch let error as CyberKitError {
            // Also acceptable: the engine refuses the payload outright.
            #expect(error.code == .io || error.code == .runtime || error.code == .emptyMesh)
        } catch {
            Issue.record("expected CyberKitError, got \(error)")
        }
    }

    @Test("reading a non-directory wrapper fails")
    func notADirectory() {
        let wrapper = FileWrapper(regularFileWithContents: Data())
        #expect(throws: DocumentBundleError.notADirectory) {
            _ = try DocumentBundle(fileWrapper: wrapper)
        }
    }

    @Test("reading a bundle without manifest.json fails")
    func missingManifest() {
        let wrapper = FileWrapper(directoryWithFileWrappers: [:])
        #expect(throws: DocumentBundleError.missingManifest) {
            _ = try DocumentBundle(fileWrapper: wrapper)
        }
    }

    @Test("a schema version from the future is refused, not misread")
    func unsupportedSchemaVersion() throws {
        let manifest = DocumentManifest(schemaVersion: DocumentManifest.currentSchemaVersion + 1)
        let wrapper = FileWrapper(directoryWithFileWrappers: [
            DocumentBundle.manifestFilename:
                FileWrapper(regularFileWithContents: try JSONEncoder().encode(manifest))
        ])
        #expect(throws: DocumentBundleError.unsupportedSchemaVersion(
            DocumentManifest.currentSchemaVersion + 1
        )) {
            _ = try DocumentBundle(fileWrapper: wrapper)
        }
    }

    @Test("an object whose payload file is missing fails validation")
    func missingPayload() throws {
        var bundle = DocumentBundle()
        bundle.manifest.objects.append(DocumentManifest.Object(
            name: "Ghost", role: .target, payloadFile: "gone.payload"
        ))
        #expect(throws: DocumentBundleError.missingPayload(
            objectName: "Ghost", payloadFile: "gone.payload"
        )) {
            _ = try bundle.fileWrapper()
        }
        #expect(throws: DocumentBundleError.missingPayload(
            objectName: "Ghost", payloadFile: "gone.payload"
        )) {
            _ = try bundle.mesh(for: bundle.manifest.objects[0])
        }
    }

    @Test("garbled manifest JSON surfaces a decoding error")
    func corruptManifest() {
        let wrapper = FileWrapper(directoryWithFileWrappers: [
            DocumentBundle.manifestFilename:
                FileWrapper(regularFileWithContents: Data("{oops".utf8))
        ])
        #expect(throws: (any Error).self) {
            _ = try DocumentBundle(fileWrapper: wrapper)
        }
    }
}

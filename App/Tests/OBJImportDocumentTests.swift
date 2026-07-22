import CyberKit
import CyberKitTesting
import Foundation
import Testing
@testable import CyberTopology

/// Document-level OBJ import over a real mesh (spec: scene-pipeline /
/// "Import formats").
///
/// This drives the exact entry point the Import Target / Import EditMesh
/// menu items reach — `TopoDocument.importMesh(at:role:)` — rather than
/// the CyberKit layer beneath it, so the app-side wiring (journaling,
/// manifest bookkeeping, undo, persistence across reopen) is covered too.
/// `OBJImportIntegrationTests` covers the loader and payload beneath.
@MainActor
struct OBJImportDocumentTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OBJImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let bunny = MeshFixtureCorpus.stanfordBunny

    /// The reported symptom is "the model doesn't appear", so assert the
    /// thing the viewport actually consumes: an object in the manifest,
    /// with the file's counts, whose mesh is readable back out.
    @Test func importingAnOBJAddsARenderableTargetObject() async throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("Import.cybertopo")
        try TopoDocument.writeNewDocument(at: url)

        let document = TopoDocument(fileURL: url)
        #expect(await openForTest(document))
        #expect(document.bundle.manifest.objects.isEmpty)

        try document.importMesh(at: MeshFixtureCorpus.stanfordBunnyURL(), role: .target)

        let object = try #require(document.bundle.manifest.objects.first)
        #expect(object.role == .target)
        // Name comes from the filename, minus extension.
        #expect(object.name == "bunny")
        let counts = try #require(object.counts)
        #expect(counts.vertices == bunny.vertexCount)
        #expect(counts.faces == bunny.faceCount)

        let mesh = try document.bundle.mesh(for: object)
        #expect(mesh.vertexCount == bunny.vertexCount)
        #expect(mesh.triangleIndices().count == bunny.faceCount * 3)

        await closeDocument(document)
    }

    /// Import is a journaled command like any other edit: one entry, and
    /// one undo takes the object back out.
    @Test func importJournalsExactlyOneUndoableEntry() async throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("ImportUndo.cybertopo")
        try TopoDocument.writeNewDocument(at: url)

        let document = TopoDocument(fileURL: url)
        #expect(await openForTest(document))

        try document.importMesh(at: MeshFixtureCorpus.stanfordBunnyURL(), role: .target)
        #expect(document.bundle.manifest.objects.count == 1)
        #expect(document.canUndo)

        document.undoLast()
        #expect(document.bundle.manifest.objects.isEmpty)

        // Redo restores it from the journaled payload, with no source file
        // read — the payload bytes travel in the command.
        document.redoLast()
        let restored = try #require(document.bundle.manifest.objects.first)
        #expect(try #require(restored.counts).faces == bunny.faceCount)

        await closeDocument(document)
    }

    /// The imported geometry must survive autosave and reopen, or the
    /// model appears at import time and is gone on the next launch.
    @Test func importedGeometryPersistsAcrossReopen() async throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("ImportPersist.cybertopo")
        try TopoDocument.writeNewDocument(at: url)

        let document = TopoDocument(fileURL: url)
        #expect(await openForTest(document))
        try document.importMesh(at: MeshFixtureCorpus.stanfordBunnyURL(), role: .editMesh)
        #expect(await autosaveForTest(document))
        await closeDocument(document)

        let reopened = TopoDocument(fileURL: url)
        #expect(await openForTest(reopened))
        let object = try #require(reopened.bundle.manifest.objects.first)
        #expect(object.role == .editMesh)
        #expect(try #require(object.counts).vertices == bunny.vertexCount)

        let mesh = try reopened.bundle.mesh(for: object)
        #expect(mesh.faceCount == bunny.faceCount)
        await closeDocument(reopened)
    }

    /// Both roles are importable into one document and stay distinct —
    /// the Import Target / Import EditMesh menu items differ only by role.
    @Test func targetAndEditMeshImportsCoexist() async throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("ImportRoles.cybertopo")
        try TopoDocument.writeNewDocument(at: url)

        let document = TopoDocument(fileURL: url)
        #expect(await openForTest(document))

        let bunnyURL = try MeshFixtureCorpus.stanfordBunnyURL()
        try document.importMesh(at: bunnyURL, role: .target)
        try document.importMesh(at: bunnyURL, role: .editMesh)

        let roles = document.bundle.manifest.objects.map(\.role)
        #expect(roles.count == 2)
        #expect(roles.contains(.target))
        #expect(roles.contains(.editMesh))

        // Distinct payload files: two imports of the same source must not
        // alias one payload, or editing the EditMesh would mutate the
        // Target.
        let payloads = Set(document.bundle.manifest.objects.map(\.payloadFile))
        #expect(payloads.count == 2)

        await closeDocument(document)
    }

    /// A failed import must leave the document untouched — no half-added
    /// object, nothing journaled.
    @Test func failedImportLeavesTheDocumentUnchanged() async throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("ImportFail.cybertopo")
        try TopoDocument.writeNewDocument(at: url)

        let document = TopoDocument(fileURL: url)
        #expect(await openForTest(document))

        let missing = directory.appendingPathComponent("nope.obj")
        #expect(throws: (any Error).self) {
            try document.importMesh(at: missing, role: .target)
        }
        #expect(document.bundle.manifest.objects.isEmpty)
        #expect(!document.canUndo)

        await closeDocument(document)
    }
}

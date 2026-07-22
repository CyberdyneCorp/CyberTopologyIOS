import CyberKit
import SwiftUI
import Testing
import UIKit
@testable import CyberTopology

@MainActor
struct RootViewTests {
    @Test func rendersDocumentBrowser() {
        let host = UIHostingController(rootView: RootView())
        host.view.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        host.view.layoutIfNeeded()

        let size = host.sizeThatFits(in: CGSize(width: 1024, height: 768))
        #expect(size.width > 0)
        #expect(size.height > 0)
    }

    @Test func appRootSceneHostsRootView() {
        let app = CyberTopologyApp()
        #expect(app.body is WindowGroup<RootView>)
    }

    /// The editor reaches the real engine through the CyberKit facade: the
    /// version label must carry a non-zero semantic version.
    @Test func editorShowsRealEngineVersion() throws {
        let document = TopoDocument(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("version-probe.cybertopo"))
        let editor = DocumentEditorView(document: document, journal: RecoveryJournal(), onClose: {})
        let match = try #require(
            editor.engineVersionText.wholeMatch(of: /Engine (\d+)\.(\d+)\.(\d+)/),
            "unexpected engine version text: \(editor.engineVersionText)"
        )
        let (major, minor, patch) = (match.1, match.2, match.3)
        #expect((major, minor, patch) != ("0", "0", "0"))
    }
}

@MainActor
struct TopoDocumentTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TopoDocumentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func newDocumentRoundTripsThroughUIDocument() async throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("RoundTrip.cybertopo")
        try TopoDocument.writeNewDocument(at: url)

        let document = TopoDocument(fileURL: url)
        #expect(await document.open())
        #expect(document.bundle.manifest.stage == .retopology)
        #expect(document.documentName == "RoundTrip")
        _ = await document.close()
    }

    @Test func editedStagePersistsAcrossReopen() async throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("StagePersists.cybertopo")
        try TopoDocument.writeNewDocument(at: url)

        let document = TopoDocument(fileURL: url)
        #expect(await document.open())
        document.updateBundle { $0.manifest.stage = .uv }
        #expect(await document.autosave())
        _ = await document.close()

        let reopened = TopoDocument(fileURL: url)
        #expect(await reopened.open())
        #expect(reopened.bundle.manifest.stage == .uv)
        _ = await reopened.close()
    }

    @Test func saveNewVersionCreatesSiblingAndKeepsOriginal() async throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("Original.cybertopo")
        try TopoDocument.writeNewDocument(at: url)

        let document = TopoDocument(fileURL: url)
        #expect(await document.open())
        document.updateBundle { $0.manifest.stage = .baking }
        let copy = try document.saveNewVersion(named: "Milestone")
        _ = await document.close()

        #expect(copy.lastPathComponent == "Milestone.cybertopo")
        #expect(FileManager.default.fileExists(atPath: url.path))

        let version = TopoDocument(fileURL: copy)
        #expect(await version.open())
        #expect(version.bundle.manifest.stage == .baking)
        _ = await version.close()
    }

    @Test func uniqueDocumentURLSuffixesOnCollision() throws {
        let directory = try temporaryDirectory()
        let first = TopoDocument.uniqueDocumentURL(named: "Untitled", in: directory)
        #expect(first.lastPathComponent == "Untitled.cybertopo")
        try TopoDocument.writeNewDocument(at: first)

        let second = TopoDocument.uniqueDocumentURL(named: "Untitled", in: directory)
        #expect(second.lastPathComponent == "Untitled 2.cybertopo")
    }
}

@MainActor
struct TopoDocumentUndoTests {
    private func openDocument() async throws -> TopoDocument {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UndoTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Undo.cybertopo")
        try TopoDocument.writeNewDocument(at: url)
        let document = TopoDocument(fileURL: url)
        #expect(await document.open())
        return document
    }

    @Test func performUndoRedoRoundTrip() async throws {
        let document = try await openDocument()
        #expect(!document.canUndo)

        document.perform(.setStage(from: .retopology, to: .uv))
        #expect(document.bundle.manifest.stage == .uv)
        #expect(document.canUndo)

        document.undoLast()
        #expect(document.bundle.manifest.stage == .retopology)
        #expect(document.canRedo)

        document.redoLast()
        #expect(document.bundle.manifest.stage == .uv)
        _ = await document.close()
    }

    @Test func deepUndoReturnsToInitialState() async throws {
        let document = try await openDocument()
        let initial = document.bundle.manifest

        for index in 0..<500 {
            let even = index.isMultiple(of: 2)
            document.perform(.setStage(from: even ? .retopology : .uv, to: even ? .uv : .retopology))
        }
        for _ in 0..<500 { document.undoLast() }

        #expect(document.bundle.manifest == initial)
        #expect(!document.canUndo)
        _ = await document.close()
    }

    /// Task 3.5 (spec: pencil-interaction / "One-tap misrecognition fix"):
    /// the chip's alternative swap replaces the LAST command atomically —
    /// exactly one journal entry afterwards, one undo steps over it — and
    /// the expected-current guard rejects stale swaps untouched.
    @Test func performReplacingLastSwapsAtomicallyAndGuardsStaleChips() async throws {
        let document = try await openDocument()
        let toUV = DocumentCommand.setStage(from: .retopology, to: .uv)
        let toBK = DocumentCommand.setStage(from: .retopology, to: .baking)

        // Nothing journaled yet: the swap is rejected untouched.
        #expect(!document.performReplacingLast(with: toBK, expecting: toUV))
        #expect(!document.canUndo)

        document.perform(toUV)
        #expect(document.bundle.manifest.stage == .uv)

        // Swap: the replacement applied on the REVERTED state and exactly
        // one entry remains.
        #expect(document.performReplacingLast(with: toBK, expecting: toUV))
        #expect(document.bundle.manifest.stage == .baking)
        #expect(document.canUndo)
        document.undoLast()
        #expect(document.bundle.manifest.stage == .retopology)
        #expect(!document.canUndo)  // ONE entry stood for stroke + swap
        document.redoLast()
        #expect(document.bundle.manifest.stage == .baking)

        // Stale chip: the journal current is now toBK, not toUV — a swap
        // expecting toUV must fail and change nothing.
        #expect(!document.performReplacingLast(with: toUV, expecting: toUV))
        #expect(document.bundle.manifest.stage == .baking)
        _ = await document.close()
    }

    @Test func journalSurvivesReopen() async throws {
        let document = try await openDocument()
        document.perform(.setStage(from: .retopology, to: .baking))
        #expect(await document.autosave())
        let url = document.fileURL
        _ = await document.close()

        let reopened = TopoDocument(fileURL: url)
        #expect(await reopened.open())
        #expect(reopened.bundle.manifest.stage == .baking)
        #expect(reopened.canUndo)
        reopened.undoLast()
        #expect(reopened.bundle.manifest.stage == .retopology)
        _ = await reopened.close()
    }
}

@MainActor
struct TopoDocumentIOTests {
    /// Colored-cube fixture shared with the CyberKit test suite.
    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // App
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("CyberKit/Tests/CyberKitTests/Fixtures/cube_colored.obj")
    }

    private func openDocument(named name: String) async throws -> TopoDocument {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).cybertopo")
        try TopoDocument.writeNewDocument(at: url)
        let document = TopoDocument(fileURL: url)
        #expect(await document.open())
        return document
    }

    @Test func importIsJournaledAndUndoable() async throws {
        let document = try await openDocument(named: "Import")
        try document.importMesh(at: fixtureURL, role: .target)

        let object = try #require(document.bundle.manifest.objects.first)
        #expect(object.role == .target)
        #expect(object.name == "cube_colored")
        #expect(object.counts == .init(vertices: 8, faces: 6))

        document.undoLast()
        #expect(document.bundle.manifest.objects.isEmpty)
        document.redoLast()
        #expect(document.bundle.manifest.objects.count == 1)
        _ = await document.close()
    }

    @Test func exportWritesToUserVisibleExportFolder() async throws {
        let document = try await openDocument(named: "Export Probe")
        try document.importMesh(at: fixtureURL, role: .editMesh)
        try document.importMesh(at: fixtureURL, role: .target)  // must not export

        let written = try document.exportEditMeshes()
        defer {
            try? FileManager.default.removeItem(
                at: URL.documentsDirectory.appendingPathComponent("Export", isDirectory: true)
            )
        }

        #expect(written.count == 2)  // one EditMesh → OBJ + MTL
        for url in written {
            #expect(url.path.contains("/Export/Export Probe/"))
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
        _ = await document.close()
    }

    @Test func importFromMissingFileThrowsAndLeavesDocumentUntouched() async throws {
        let document = try await openDocument(named: "Missing")
        let bogus = URL(fileURLWithPath: "/tmp/definitely-missing-\(UUID()).obj")
        #expect(throws: (any Error).self) {
            try document.importMesh(at: bogus, role: .target)
        }
        #expect(document.bundle.manifest.objects.isEmpty)
        #expect(!document.canUndo)
        _ = await document.close()
    }
}

@MainActor
struct DocumentEditorViewTests {
    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CyberKit/Tests/CyberKitTests/Fixtures/cube_colored.obj")
    }

    private func openDocument() async throws -> TopoDocument {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Editor.cybertopo")
        try TopoDocument.writeNewDocument(at: url)
        let document = TopoDocument(fileURL: url)
        #expect(await document.open())
        return document
    }

    @Test func rendersWithImportedObjects() async throws {
        let document = try await openDocument()
        try document.importMesh(at: fixtureURL, role: .target)
        try document.importMesh(at: fixtureURL, role: .editMesh)

        let editor = DocumentEditorView(document: document, journal: RecoveryJournal(), onClose: {})
        let host = UIHostingController(rootView: editor)
        host.view.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        host.view.layoutIfNeeded()
        #expect(host.sizeThatFits(in: CGSize(width: 1024, height: 768)).height > 0)
        _ = await document.close()
    }

    @Test func handleImportAcceptsFBXThroughTheSamePath() async throws {
        // Task 3.10: the Files-picker result path dispatches by extension —
        // an FBX lands as a journaled object with counts, exactly like OBJ.
        let document = try await openDocument()
        let editor = DocumentEditorView(document: document, journal: RecoveryJournal(), onClose: {})
        let fbxURL = fixtureURL.deletingPathExtension().appendingPathExtension("fbx")

        editor.handleImport(.success(fbxURL), role: .target)
        let object = try #require(document.bundle.manifest.objects.first)
        #expect(object.role == .target)
        #expect(object.name == "cube_colored")
        #expect(object.counts == .init(vertices: 8, faces: 6))
        #expect(document.canUndo)

        // Unsupported extensions surface as an import failure, not a crash.
        editor.handleImport(
            .success(URL(fileURLWithPath: "/tmp/mesh-\(UUID()).usdz")), role: .target
        )
        #expect(document.bundle.manifest.objects.count == 1)
        _ = await document.close()
    }

    @Test func handleImportSuccessAndFailurePaths() async throws {
        let document = try await openDocument()
        let editor = DocumentEditorView(document: document, journal: RecoveryJournal(), onClose: {})

        editor.handleImport(.success(fixtureURL), role: .editMesh)
        #expect(document.bundle.manifest.objects.count == 1)

        struct ProbeError: Error {}
        editor.handleImport(.failure(ProbeError()), role: .editMesh)
        #expect(document.bundle.manifest.objects.count == 1)

        editor.handleImport(
            .success(URL(fileURLWithPath: "/tmp/missing-\(UUID()).obj")), role: .target
        )
        #expect(document.bundle.manifest.objects.count == 1)
        _ = await document.close()
    }

    @Test func exportNowWritesFiles() async throws {
        let document = try await openDocument()
        try document.importMesh(at: fixtureURL, role: .editMesh)
        let editor = DocumentEditorView(document: document, journal: RecoveryJournal(), onClose: {})

        editor.exportNow()
        defer {
            try? FileManager.default.removeItem(
                at: URL.documentsDirectory.appendingPathComponent("Export", isDirectory: true)
            )
        }
        let exported = URL.documentsDirectory
            .appendingPathComponent("Export/Editor/cube_colored.obj")
        #expect(FileManager.default.fileExists(atPath: exported.path))
        _ = await document.close()
    }
}

@MainActor
struct UITestSupportTests {
    @Test func seedOBJIsLoadableByTheEngine() throws {
        let url = try UITestSupport.writeSeedOBJ()
        let mesh = try CyberKit.Mesh.loadOBJ(at: url)
        #expect(mesh.vertexCount == 4)
        #expect(mesh.faceCount == 1)
    }
}

@MainActor
struct UndoGestureViewTests {
    @Test func coordinatorRoutesTapsToHandlers() {
        var undone = 0
        var redone = 0
        let view = UndoGestureView(onUndo: { undone += 1 }, onRedo: { redone += 1 })
        let coordinator = view.makeCoordinator()

        coordinator.undoTap()
        coordinator.redoTap()
        coordinator.redoTap()
        #expect(undone == 1)
        #expect(redone == 2)
    }

    @Test func viewInstallsTwoAndThreeFingerRecognizers() {
        let view = UndoGestureView(onUndo: {}, onRedo: {})
        let uiView = UndoGestureView.makeConfiguredView(coordinator: view.makeCoordinator())
        let taps = uiView.gestureRecognizers?.compactMap { $0 as? UITapGestureRecognizer } ?? []
        #expect(taps.map(\.numberOfTouchesRequired).sorted() == [3, 4])
    }
}

@MainActor
struct DocumentBrowserCoordinatorTests {
    private func makeCoordinator(
        onOpen: @escaping @MainActor (URL) -> Void = { _ in }
    ) -> DocumentBrowserView.Coordinator {
        DocumentBrowserView(onOpen: onOpen).makeCoordinator()
    }

    @Test func createDocumentWritesFileAndOpensIt() throws {
        var opened: URL?
        let coordinator = makeCoordinator { opened = $0 }
        coordinator.createDocument()

        let url = try #require(opened)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(url.pathExtension == TopoDocument.fileExtension)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(url.deletingLastPathComponent().path == URL.documentsDirectory.path)
    }

    @Test func templateDocumentIsAValidBundle() async throws {
        let url = try DocumentBrowserView.Coordinator.makeTemplateDocument()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let document = TopoDocument(fileURL: url)
        #expect(await document.open())
        #expect(document.bundle.manifest.stage == .retopology)
        _ = await document.close()
    }

    @Test func systemCreationRequestSuppliesTemplateWithMoveMode() {
        let coordinator = makeCoordinator()
        let browser = UIDocumentBrowserViewController(forOpening: [.cybertopoDocument])

        var received: (URL?, UIDocumentBrowserViewController.ImportMode)?
        coordinator.documentBrowser(
            browser,
            didRequestDocumentCreationWithHandler: { url, mode in received = (url, mode) }
        )

        #expect(received?.1 == .move)
        if let url = received?.0 {
            #expect(FileManager.default.fileExists(atPath: url.path))
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        } else {
            Issue.record("no template URL supplied")
        }
    }

    @Test func pickAndImportForwardToOnOpen() {
        var opened: [URL] = []
        let coordinator = makeCoordinator { opened.append($0) }
        let browser = UIDocumentBrowserViewController(forOpening: [.cybertopoDocument])
        let picked = URL(fileURLWithPath: "/tmp/picked.cybertopo")
        let imported = URL(fileURLWithPath: "/tmp/imported.cybertopo")

        coordinator.documentBrowser(browser, didPickDocumentsAt: [picked])
        coordinator.documentBrowser(
            browser, didImportDocumentAt: URL(fileURLWithPath: "/tmp/src"),
            toDestinationURL: imported
        )
        coordinator.documentBrowser(browser, didPickDocumentsAt: [])

        #expect(opened.map(\.lastPathComponent) == ["picked.cybertopo", "imported.cybertopo"])
    }
}

struct RecoveryJournalReducerTests {
    typealias State = RecoveryJournal.State
    private let url = URL(fileURLWithPath: "/tmp/probe.cybertopo")

    @Test func openThenCloseIsClean() {
        var state = State.idle
        state = RecoveryJournal.reduce(state, .documentOpened(url))
        #expect(state == .active(documentPath: url.path, hasUnsavedChanges: false))
        state = RecoveryJournal.reduce(state, .documentClosed)
        #expect(state == .idle)
    }

    @Test func editMarksDirtySaveMarksClean() {
        var state = RecoveryJournal.reduce(.idle, .documentOpened(url))
        state = RecoveryJournal.reduce(state, .documentEdited)
        #expect(state == .active(documentPath: url.path, hasUnsavedChanges: true))
        state = RecoveryJournal.reduce(state, .documentSaved)
        #expect(state == .active(documentPath: url.path, hasUnsavedChanges: false))
    }

    @Test func idleIgnoresEditAndSave() {
        #expect(RecoveryJournal.reduce(.idle, .documentEdited) == .idle)
        #expect(RecoveryJournal.reduce(.idle, .documentSaved) == .idle)
    }
}

@MainActor
struct RecoveryJournalPersistenceTests {
    private func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("journal-\(UUID().uuidString).json")
    }

    @Test func activeSessionWithExistingFileIsRecovered() throws {
        let store = temporaryStoreURL()
        let documentURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Recovered-\(UUID().uuidString).cybertopo")
        try TopoDocument.writeNewDocument(at: documentURL)

        let crashed = RecoveryJournal(storeURL: store)
        crashed.handle(.documentOpened(documentURL))
        // No .documentClosed: simulates a crash/force-quit.

        let relaunched = RecoveryJournal(storeURL: store)
        // Path comparison: URL(fileURLWithPath:) may add a trailing slash for
        // package directories, so direct URL equality is too strict.
        #expect(relaunched.recoveredSessionURL?.standardizedFileURL.path
            == documentURL.standardizedFileURL.path)
    }

    @Test func cleanCloseLeavesNothingToRecover() {
        let store = temporaryStoreURL()
        let journal = RecoveryJournal(storeURL: store)
        journal.handle(.documentOpened(URL(fileURLWithPath: "/tmp/x.cybertopo")))
        journal.handle(.documentClosed)

        let relaunched = RecoveryJournal(storeURL: store)
        #expect(relaunched.recoveredSessionURL == nil)
    }

    @Test func missingDocumentFileIsNotRecovered() {
        let store = temporaryStoreURL()
        let journal = RecoveryJournal(storeURL: store)
        journal.handle(.documentOpened(URL(fileURLWithPath: "/tmp/deleted-\(UUID()).cybertopo")))

        let relaunched = RecoveryJournal(storeURL: store)
        #expect(relaunched.recoveredSessionURL == nil)
    }

    @Test func corruptJournalDegradesToCleanStart() throws {
        let store = temporaryStoreURL()
        try Data("not json".utf8).write(to: store)

        let journal = RecoveryJournal(storeURL: store)
        #expect(journal.state == .idle)
        #expect(journal.recoveredSessionURL == nil)
    }
}

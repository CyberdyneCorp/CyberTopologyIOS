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

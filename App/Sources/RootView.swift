import SwiftUI

/// App root: document browser, with the editor presented full-screen over it
/// while a document is open. On first appearance, a session left open by a
/// crash/force-quit is reopened from the recovery journal.
struct RootView: View {
    @State private var journal = RecoveryJournal()
    @State private var openDocument: TopoDocument?
    @State private var didCheckRecovery = false

    var body: some View {
        DocumentBrowserView(onOpen: open)
            .ignoresSafeArea()
            .fullScreenCover(item: $openDocument) { document in
                DocumentEditorView(document: document, journal: journal, onClose: close)
            }
            .task {
                guard !didCheckRecovery else { return }
                didCheckRecovery = true
                if let url = journal.recoveredSessionURL {
                    open(url)
                } else if UITestSupport.openDocumentRequested {
                    openTestDocument()
                }
            }
    }

    // The TopoDocument is created INSIDE each task so the non-Sendable
    // document never crosses an isolation boundary: newer Swift compilers
    // (Xcode 26.6+) reject capturing it from the enclosing context even
    // though both sides are MainActor.
    private func open(_ url: URL) {
        Task { @MainActor in
            let document = TopoDocument(fileURL: url)
            guard await document.open() else { return }
            journal.handle(.documentOpened(url))
            openDocument = document
        }
    }

    /// UI-test entry point: open-or-create the fixed test document (see
    /// `UITestSupport.openDocumentArgument`), optionally seeding an
    /// EditMesh object for object-list/export flows.
    private func openTestDocument() {
        let url = UITestSupport.testDocumentURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? TopoDocument.writeNewDocument(at: url)
        }
        Task { @MainActor in
            let document = TopoDocument(fileURL: url)
            guard await document.open() else { return }
            let objects = document.bundle.manifest.objects
            if UITestSupport.seedTargetRequested,
                !objects.contains(where: { $0.role == .target }),
                let seed = try? UITestSupport.writeSeedTargetOBJ() {
                try? document.importMesh(at: seed, role: .target)
            }
            if UITestSupport.seedEditMeshRequested,
                !objects.contains(where: { $0.role == .editMesh }),
                let seed = try? UITestSupport.writeSeedOBJ() {
                try? document.importMesh(at: seed, role: .editMesh)
            }
            if UITestSupport.seedEditMeshStripRequested,
                !objects.contains(where: { $0.role == .editMesh }),
                let seed = try? UITestSupport.writeSeedStripOBJ() {
                try? document.importMesh(at: seed, role: .editMesh)
            }
            if UITestSupport.seedEditMeshOnDomeRequested,
                !objects.contains(where: { $0.role == .editMesh }),
                let seed = try? UITestSupport.writeSeedDomeStripOBJ() {
                try? document.importMesh(at: seed, role: .editMesh)
            }
            journal.handle(.documentOpened(url))
            openDocument = document
        }
    }

    private func close() {
        guard let document = openDocument else { return }
        // nonisolated(unsafe): MainActor-to-MainActor Task capture of the
        // non-Sendable UIDocument. Safe by the document's thread contract
        // (all bundle mutations happen on MainActor; UIDocument snapshots
        // contents on the initiating queue). Newer compilers (Xcode 26.6+)
        // reject the plain capture; @unchecked Sendable on the class trips
        // their nonisolated synthesis on @Published instead.
        nonisolated(unsafe) let closing = document
        Task { @MainActor in
            // UIDocument.close autosaves pending changes before closing.
            _ = await closing.close()
            journal.handle(.documentClosed)
            openDocument = nil
        }
    }
}

/// `fullScreenCover(item:)` identity: one editor per document instance.
extension TopoDocument: Identifiable {}


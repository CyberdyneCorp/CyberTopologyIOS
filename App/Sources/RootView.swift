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

    private func open(_ url: URL) {
        let document = TopoDocument(fileURL: url)
        Task { @MainActor in
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
        let document = TopoDocument(fileURL: url)
        Task { @MainActor in
            guard await document.open() else { return }
            if UITestSupport.seedEditMeshRequested,
                document.bundle.manifest.objects.isEmpty,
                let seed = try? UITestSupport.writeSeedOBJ() {
                try? document.importOBJ(at: seed, role: .editMesh)
            }
            journal.handle(.documentOpened(url))
            openDocument = document
        }
    }

    private func close() {
        guard let document = openDocument else { return }
        Task { @MainActor in
            // UIDocument.close autosaves pending changes before closing.
            _ = await document.close()
            journal.handle(.documentClosed)
            openDocument = nil
        }
    }
}

/// `fullScreenCover(item:)` identity: one editor per document instance.
extension TopoDocument: Identifiable {}

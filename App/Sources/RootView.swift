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

/// Thread contract (checked by hand, enforced by convention): every app
/// mutation of `bundle` goes through MainActor paths (perform/undoLast/
/// redoLast/updateBundle are only called from MainActor UI code), and
/// UIDocument invokes `contents(forType:)` on the queue that initiated the
/// save (main) before handing the snapshot to its background writer — the
/// background queue never touches `bundle` directly. Newer Swift compilers
/// (Xcode 26.6+) reject even MainActor-to-MainActor Task captures of
/// non-Sendable classes, so the contract is declared explicitly here.
/// Revisit if a non-MainActor mutation path is ever added.
extension TopoDocument: @unchecked Sendable {}

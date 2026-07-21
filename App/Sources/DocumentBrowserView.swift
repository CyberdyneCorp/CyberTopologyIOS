import SwiftUI
import UIKit

/// SwiftUI host for the system document browser (spec: document-model /
/// "User-visible document storage"). Documents are created in the app's
/// Files-app-visible Documents folder (`UIFileSharingEnabled` +
/// `LSSupportsOpeningDocumentsInPlace` + `UISupportsDocumentBrowser`).
struct DocumentBrowserView: UIViewControllerRepresentable {
    /// Called with the URL of the document to open (picked or just created).
    let onOpen: @MainActor (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentBrowserViewController {
        let browser = UIDocumentBrowserViewController(forOpening: [.cybertopoDocument])
        browser.allowsDocumentCreation = true
        browser.allowsPickingMultipleItems = false
        browser.delegate = context.coordinator

        // Explicit creation affordance next to the system tile: one tap, no
        // location picker (used by UI tests as the deterministic entry point).
        let create = UIBarButtonItem(
            title: "New Document",
            style: .plain,
            target: context.coordinator,
            action: #selector(Coordinator.createDocument)
        )
        create.accessibilityIdentifier = "create-document"
        browser.additionalTrailingNavigationBarButtonItems = [create]
        return browser
    }

    func updateUIViewController(_ controller: UIDocumentBrowserViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onOpen: onOpen)
    }

    // @preconcurrency: the delegate protocol is nonisolated in the SDK, but
    // UIKit only calls it on the main thread, where this class is isolated.
    @MainActor
    final class Coordinator: NSObject, @preconcurrency UIDocumentBrowserViewControllerDelegate {
        let onOpen: @MainActor (URL) -> Void

        init(onOpen: @escaping @MainActor (URL) -> Void) {
            self.onOpen = onOpen
        }

        /// Creates a new document directly in the app's Documents folder and
        /// opens it.
        @objc func createDocument() {
            do {
                let url = try Self.createNewDocumentInDocumentsFolder()
                onOpen(url)
            } catch {
                assertionFailure("document creation failed: \(error)")
            }
        }

        static func createNewDocumentInDocumentsFolder() throws -> URL {
            let url = TopoDocument.uniqueDocumentURL(named: "Untitled", in: .documentsDirectory)
            try TopoDocument.writeNewDocument(at: url)
            return url
        }

        // MARK: UIDocumentBrowserViewControllerDelegate

        /// System "Create Document" tile: hand the browser a template to move
        /// into the location the user picked.
        func documentBrowser(
            _ controller: UIDocumentBrowserViewController,
            didRequestDocumentCreationWithHandler importHandler:
                @escaping (URL?, UIDocumentBrowserViewController.ImportMode) -> Void
        ) {
            do {
                importHandler(try Self.makeTemplateDocument(), .move)
            } catch {
                importHandler(nil, .none)
            }
        }

        static func makeTemplateDocument() throws -> URL {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("NewDocument-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory
                .appendingPathComponent("Untitled")
                .appendingPathExtension(TopoDocument.fileExtension)
            try TopoDocument.writeNewDocument(at: url)
            return url
        }

        func documentBrowser(
            _ controller: UIDocumentBrowserViewController, didPickDocumentsAt documentURLs: [URL]
        ) {
            if let url = documentURLs.first { onOpen(url) }
        }

        func documentBrowser(
            _ controller: UIDocumentBrowserViewController,
            didImportDocumentAt sourceURL: URL,
            toDestinationURL destinationURL: URL
        ) {
            onOpen(destinationURL)
        }
    }
}

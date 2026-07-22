import SwiftUI

/// What a full-screen-cover dismissal must do, as a PURE decision so the
/// ordering contract is unit-testable without a UIKit presentation.
///
/// The contract: the dismissed `UIDocument` is ALWAYS closed (it is still
/// open as a file presenter with pending autosave — SwiftUI only dropped
/// the binding), and any re-open happens strictly AFTER that close. Two
/// open `UIDocument`s on one bundle would both autosave it, and the
/// recovery journal's open/close pairing would record two
/// `.documentOpened` with no `.documentClosed` between them.
enum CoverDismissalPlan: Equatable {
    /// An explicit `close()` drove this dismissal and already closed the
    /// document and journaled `.documentClosed`. Nothing more to do.
    case requestedClose
    /// Unrequested: close the dismissed document, then re-open the URL.
    case closeThenReopen(URL)
    /// Unrequested but the retry budget is spent: close and stay on the
    /// browser (a re-open loop would be worse than the bug it fixes).
    case closeAndGiveUp

    static func plan(
        intendedURL: URL?, reopens: Int, limit: Int
    ) -> CoverDismissalPlan {
        guard let intendedURL else { return .requestedClose }
        return reopens < limit ? .closeThenReopen(intendedURL) : .closeAndGiveUp
    }

    /// Whether this plan must close the dismissed document itself.
    var closesDismissedDocument: Bool { self != .requestedClose }
}

/// App root: document browser, with the editor presented full-screen over it
/// while a document is open. On first appearance, a session left open by a
/// crash/force-quit is reopened from the recovery journal.
struct RootView: View {
    @State private var journal = RecoveryJournal()
    @State private var openDocument: TopoDocument?
    @State private var didCheckRecovery = false
    /// The URL the user is currently meant to have open. Set when a
    /// document is opened, cleared only by an explicit `close()`.
    ///
    /// The system document browser owns the presentation this editor is
    /// hosted in, and it dismisses whatever is presented over it during
    /// its own initial reveal/restoration work — which under load can land
    /// AFTER the auto-open has already put the editor on screen. The
    /// editor then vanishes back to the browser with no `close()` ever
    /// running: the `UIDocument` is left open (leaked, and the recovery
    /// journal never sees `documentClosed`), and any UI test driving the
    /// editor fails from that point on. This field is what lets
    /// `onDismiss` tell an unrequested dismissal from a real close.
    @State private var intendedDocumentURL: URL?
    /// How many unrequested dismissals have been recovered from. Bounded:
    /// a re-open loop against a browser that keeps dismissing would be
    /// worse than the bug it fixes, so after `maxUnrequestedReopens` the
    /// user is simply left on the browser and can re-open by hand.
    @State private var unrequestedReopens = 0
    private static let maxUnrequestedReopens = 2
    /// Strong reference to the document the cover is presenting.
    ///
    /// `fullScreenCover(item:)` clears `$openDocument` BEFORE `onDismiss`
    /// runs, so without this the unrequested-dismissal path has nothing to
    /// close: the `UIDocument` stays open as a file presenter with pending
    /// autosave, and re-opening the same URL would put a SECOND open
    /// `TopoDocument` on the same bundle and record a second
    /// `.documentOpened` with no `.documentClosed` between them. Cleared by
    /// `close()` (which does its own closing) so `coverDismissed` can tell
    /// the two dismissals apart by this too.
    @State private var presentedDocument: TopoDocument?

    var body: some View {
        DocumentBrowserView(onOpen: { open($0) })
            .ignoresSafeArea()
            .fullScreenCover(item: $openDocument, onDismiss: coverDismissed) { document in
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
    /// - Parameter closing: a still-open document to close (and journal)
    ///   BEFORE the new one opens, so the journal never holds two
    ///   overlapping `.documentOpened` entries and two `UIDocument`
    ///   instances never autosave the same bundle. Both halves run in ONE
    ///   task so the ordering is guaranteed.
    private func open(_ url: URL, closing outgoing: TopoDocument? = nil) {
        // nonisolated(unsafe): see `close()` — MainActor-to-MainActor Task
        // capture of the non-Sendable UIDocument.
        nonisolated(unsafe) let outgoing = outgoing
        Task { @MainActor in
            if let outgoing {
                _ = await outgoing.close()
                journal.handle(.documentClosed)
            }
            let document = TopoDocument(fileURL: url)
            guard await document.open() else { return }
            journal.handle(.documentOpened(url))
            intendedDocumentURL = url
            presentedDocument = document
            openDocument = document
        }
    }

    /// The full-screen cover went away. A real close has already cleared
    /// `intendedDocumentURL` (and `presentedDocument`, and done its own
    /// closing); anything else is the browser dismissing a presentation it
    /// did not expect, and the document is re-opened so the user is not
    /// silently thrown out of their editing session — but only after the
    /// dismissed instance is properly closed.
    private func coverDismissed() {
        let plan = CoverDismissalPlan.plan(
            intendedURL: intendedDocumentURL,
            reopens: unrequestedReopens,
            limit: Self.maxUnrequestedReopens
        )
        let dismissed = plan.closesDismissedDocument ? presentedDocument : nil
        presentedDocument = nil
        switch plan {
        case .requestedClose:
            break  // `close()` already closed it and journaled the close.
        case .closeAndGiveUp:
            intendedDocumentURL = nil
            closeDismissed(dismissed)
        case .closeThenReopen(let url):
            unrequestedReopens += 1
            open(url, closing: dismissed)
        }
    }

    /// Closes a document whose cover was dismissed without a `close()`,
    /// journaling the `.documentClosed` the dismissal never produced.
    private func closeDismissed(_ document: TopoDocument?) {
        guard let document else { return }
        nonisolated(unsafe) let closing = document
        Task { @MainActor in
            _ = await closing.close()
            journal.handle(.documentClosed)
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
            if UITestSupport.seedEditMeshGridRequested,
                !objects.contains(where: { $0.role == .editMesh }),
                let seed = try? UITestSupport.writeSeedDomeGridOBJ() {
                try? document.importMesh(at: seed, role: .editMesh)
            }
            if UITestSupport.seedEditMeshOnDomeRequested,
                !objects.contains(where: { $0.role == .editMesh }),
                let seed = try? UITestSupport.writeSeedDomeStripOBJ() {
                try? document.importMesh(at: seed, role: .editMesh)
            }
            journal.handle(.documentOpened(url))
            intendedDocumentURL = url
            presentedDocument = document
            openDocument = document
        }
    }

    private func close() {
        guard let document = openDocument else { return }
        // Cleared FIRST: `onDismiss` fires as the cover goes away and must
        // see that this dismissal was requested — and that the document is
        // already being closed here, so it must not be closed twice.
        intendedDocumentURL = nil
        presentedDocument = nil
        unrequestedReopens = 0
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


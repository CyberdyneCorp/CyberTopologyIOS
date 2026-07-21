import Foundation

/// Crash-recovery journal (spec: document-model / "Crash recovery").
///
/// Persists whether a document session is open so a crash or force-quit can
/// be detected on the next launch:
///
///     idle ──documentOpened──▶ active(clean) ──documentEdited──▶ active(dirty)
///       ▲                            ▲                                │
///       └────────documentClosed──────┴──────────documentSaved─────────┘
///
/// Every transition is written to disk immediately. A journal that still
/// reads `active` at launch means the previous session never closed cleanly,
/// so `recoveredSessionURL` points at the document to reopen (its content is
/// at worst one autosave interval old — UIDocument autosaves on change and
/// the editor forces one on backgrounding).
@MainActor
final class RecoveryJournal {
    enum State: Equatable, Codable {
        case idle
        case active(documentPath: String, hasUnsavedChanges: Bool)
    }

    enum Event {
        case documentOpened(URL)
        case documentEdited
        case documentSaved
        case documentClosed
    }

    let storeURL: URL
    private(set) var state: State

    /// Document left open by a previous session that did not close cleanly,
    /// captured at init before this session overwrites the journal.
    let recoveredSessionURL: URL?

    init(storeURL: URL = RecoveryJournal.defaultStoreURL()) {
        self.storeURL = storeURL
        // A missing or corrupt journal degrades to a clean start, never a crash.
        let persisted = (try? Data(contentsOf: storeURL))
            .flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? .idle
        state = persisted
        if case .active(let path, _) = persisted,
            FileManager.default.fileExists(atPath: path) {
            recoveredSessionURL = URL(fileURLWithPath: path)
        } else {
            recoveredSessionURL = nil
        }
    }

    func handle(_ event: Event) {
        state = Self.reduce(state, event)
        persist()
    }

    /// Pure transition function (unit-tested exhaustively).
    nonisolated static func reduce(_ state: State, _ event: Event) -> State {
        switch (state, event) {
        case (_, .documentOpened(let url)):
            return .active(documentPath: url.path, hasUnsavedChanges: false)
        case (.active(let path, _), .documentEdited):
            return .active(documentPath: path, hasUnsavedChanges: true)
        case (.active(let path, _), .documentSaved):
            return .active(documentPath: path, hasUnsavedChanges: false)
        case (_, .documentClosed):
            return .idle
        case (.idle, .documentEdited), (.idle, .documentSaved):
            return .idle // no session: nothing to record
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try JSONEncoder().encode(state).write(to: storeURL, options: .atomic)
        } catch {
            // Journal loss only costs crash recovery, never user data.
            assertionFailure("RecoveryJournal persist failed: \(error)")
        }
    }

    nonisolated static func defaultStoreURL() -> URL {
        URL.applicationSupportDirectory.appendingPathComponent("RecoveryJournal.json")
    }
}

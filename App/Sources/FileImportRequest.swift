import CyberKit

/// Pending file-import request driving the `fileImporter` sheet.
///
/// REGRESSION (device): presentation and payload used to be the SAME
/// optional — `isPresented: Binding(get: { importRole != nil }, set: { if
/// !$0 { importRole = nil } })` — with the completion handler reading
/// `importRole` back out. SwiftUI dismisses the picker BEFORE invoking
/// `onCompletion`, and that dismissal drives the binding to `false`, whose
/// setter nils the role. So the completion's `if let role` never matched:
/// every import was discarded with no object added and no error shown,
/// which on device is indistinguishable from a broken importer.
///
/// The fix is to stop deriving one from the other. `isPresented` is its own
/// flag; the role outlives dismissal and is consumed exactly once by the
/// completion. Both halves are asserted in `FileImportRequestTests`.
struct FileImportRequest: Equatable {
    /// Drives the sheet. Independent of `role` by design — see above.
    var isPresented = false

    /// What the completed picker session should DO with the file.
    ///
    /// An intent rather than a bare role (6.1a), because a UV-only project import is
    /// `role: .editMesh` PLUS a stage switch. Carrying the extra decision as a second flag
    /// beside `role` would let the two desync — which is precisely the regression this struct
    /// exists to prevent — so there is one value and the role is derived from it.
    enum Intent: Equatable {
        case target
        case editMesh
        /// Import as the EditMesh with no Target and open in the UV stage, as one undo step.
        case uvOnlyProject

        var role: DocumentManifest.Object.Role {
            switch self {
            case .target: return .target
            case .editMesh, .uvOnlyProject: return .editMesh
            }
        }
    }

    /// Intent the completed picker session should apply. Survives dismissal; cleared only by
    /// `consumeIntent()`.
    private(set) var intent: Intent?

    /// The role the pending session would import as, or nil when none is pending.
    var role: DocumentManifest.Object.Role? { intent?.role }

    /// Opens the picker for `intent`.
    mutating func begin(_ intent: Intent) {
        self.intent = intent
        isPresented = true
    }

    /// Intent for the session that just completed, consumed exactly once so a second completion
    /// (or a stale one) cannot import again.
    mutating func consumeIntent() -> Intent? {
        defer { intent = nil }
        return intent
    }

    /// Role for the session that just completed, consumed exactly once.
    mutating func consumeRole() -> DocumentManifest.Object.Role? {
        consumeIntent()?.role
    }
}

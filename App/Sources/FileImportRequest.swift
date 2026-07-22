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

    /// Role the completed picker session should import as. Survives
    /// dismissal; cleared only by `consumeRole()`.
    private(set) var role: DocumentManifest.Object.Role?

    /// Opens the picker for `role`.
    mutating func begin(_ role: DocumentManifest.Object.Role) {
        self.role = role
        isPresented = true
    }

    /// Role for the session that just completed, consumed exactly once so
    /// a second completion (or a stale one) cannot import again.
    mutating func consumeRole() -> DocumentManifest.Object.Role? {
        defer { role = nil }
        return role
    }
}

import CyberKit
import Testing
@testable import CyberTopology

/// REGRESSION (device): imports were silently discarded — no object added,
/// no error shown — because presentation and payload were the same state.
///
/// The old wiring derived `isPresented` from the role optional and nilled
/// the role in the binding's setter. SwiftUI dismisses the picker BEFORE
/// invoking `onCompletion`, so the role was always gone by the time the
/// completion read it, and `if let role` never matched.
///
/// These tests replay that ordering explicitly: dismiss first, THEN
/// complete. Anything that reintroduces the coupling fails here.
struct FileImportRequestTests {
    @Test func beginningPresentsTheSheetAndRecordsTheRole() {
        var request = FileImportRequest()
        #expect(!request.isPresented)
        #expect(request.role == nil)

        request.begin(.target)
        #expect(request.isPresented)
        #expect(request.role == .target)
    }

    /// The load-bearing assertion: dismissal must NOT destroy the role, or
    /// the completion handler has nothing to import as.
    @Test func roleSurvivesDismissalSoTheCompletionCanStillImport() {
        var request = FileImportRequest()
        request.begin(.target)

        // Exactly what SwiftUI does when the picker closes.
        request.isPresented = false

        // ...and only THEN does onCompletion run.
        #expect(request.consumeRole() == .target)
    }

    @Test func roleSurvivesDismissalForEditMeshToo() {
        var request = FileImportRequest()
        request.begin(.editMesh)
        request.isPresented = false
        #expect(request.consumeRole() == .editMesh)
    }

    /// Consumed exactly once: a second completion for the same session must
    /// not import again.
    @Test func roleIsConsumedOnlyOnce() {
        var request = FileImportRequest()
        request.begin(.target)
        request.isPresented = false

        #expect(request.consumeRole() == .target)
        #expect(request.consumeRole() == nil)
        #expect(request.role == nil)
    }

    /// A completion with no session pending imports nothing.
    @Test func completionWithoutABegunSessionImportsNothing() {
        var request = FileImportRequest()
        #expect(request.consumeRole() == nil)
    }

    /// Re-opening for a different role replaces the pending one rather than
    /// leaving the first to fire later.
    @Test func beginningAgainReplacesThePendingRole() {
        var request = FileImportRequest()
        request.begin(.target)
        request.begin(.editMesh)

        #expect(request.isPresented)
        #expect(request.consumeRole() == .editMesh)
        #expect(request.consumeRole() == nil)
    }
}

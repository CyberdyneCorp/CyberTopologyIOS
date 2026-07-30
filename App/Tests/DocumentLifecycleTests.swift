import Foundation
import Testing
@testable import CyberTopology

/// `TopoDocument`'s main-actor lifecycle wrappers — `openForEditing`,
/// `closeSavingChanges`, `autosaveChanges` (see "Main-actor lifecycle" there).
///
/// REGRESSION. These replaced direct `await document.open()` / `.close()` /
/// `.autosave()` calls, which sent the non-Sendable document across an
/// isolation boundary: "sending value of non-Sendable type 'TopoDocument'".
/// Xcode 26.0 accepts that, the Xcode 26.6 compiler rejects it, and CI selects
/// the newest installed Xcode — so the break only ever appeared in CI.
///
/// The compile is what CI guards; these tests guard the bridge underneath it.
/// Wrapping a callback API in a continuation adds two failure modes a plain
/// `await` could not have: a continuation that is never resumed (hangs — hence
/// the time limits) and one resumed twice (traps). The `Bool` matters too:
/// `RootView.open` bails via `guard await openForEditing() else { return }`.
@MainActor
struct DocumentLifecycleTests {
    /// `Thread.isMainThread` is unavailable from an async context, so the read
    /// happens in this synchronous main-actor hop instead.
    private func resumedOnMainThread() -> Bool { Thread.isMainThread }

    private func newDocumentURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Lifecycle.cybertopo")
        try TopoDocument.writeNewDocument(at: url)
        return url
    }

    /// All three wrappers resume, report UIKit's own result, and come back on
    /// the main actor — that last part is the contract that lets the callers
    /// touch `@State` and the journal straight after the `await`.
    @Test(.timeLimit(.minutes(1)))
    func eachWrapperResumesOnTheMainActor() async throws {
        let document = TopoDocument(fileURL: try newDocumentURL())

        #expect(await document.openForEditing())
        #expect(resumedOnMainThread(), "openForEditing must resume on the main actor")

        document.updateBundle { $0.manifest.stage = .uv }
        #expect(await document.autosaveChanges())
        #expect(resumedOnMainThread(), "autosaveChanges must resume on the main actor")

        #expect(await document.closeSavingChanges())
        #expect(resumedOnMainThread(), "closeSavingChanges must resume on the main actor")
    }

    /// A failed open must REPORT failure rather than trap or hang: the callers
    /// treat the `Bool` as "is there a document to present".
    @Test(.timeLimit(.minutes(1)))
    func openingAMissingDocumentReportsFailure() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("Missing-\(UUID().uuidString).cybertopo")
        let document = TopoDocument(fileURL: missing)

        #expect(await document.openForEditing() == false)
    }

    /// The bridge is only correct if it actually persists: autosave through the
    /// wrapper, then reopen from disk with a fresh instance and read it back.
    @Test(.timeLimit(.minutes(1)))
    func autosaveThroughTheWrapperReachesDisk() async throws {
        let url = try newDocumentURL()
        let document = TopoDocument(fileURL: url)
        #expect(await document.openForEditing())
        #expect(document.bundle.manifest.stage == .retopology)

        document.updateBundle { $0.manifest.stage = .baking }
        #expect(await document.autosaveChanges())
        #expect(await document.closeSavingChanges())

        let reopened = TopoDocument(fileURL: url)
        #expect(await reopened.openForEditing())
        #expect(reopened.bundle.manifest.stage == .baking, "the autosave never reached disk")
        #expect(await reopened.closeSavingChanges())
    }
}

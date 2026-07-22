import Foundation
@testable import CyberTopology

// UIDocument's open/close/autosave are nonisolated async methods; awaiting
// them on a non-Sendable TopoDocument from MainActor test code is flagged
// as a send by Xcode 26.6+ compilers (local 26.0 accepts it — the failures
// only reproduce in CI). These helpers carry the documented
// nonisolated(unsafe) contract in one place: UIDocument manages its own
// queues, and all bundle mutations happen on MainActor.

@MainActor
func openForTest(_ document: TopoDocument) async -> Bool {
    nonisolated(unsafe) let opening = document
    return await opening.open()
}

@MainActor
func closeDocument(_ document: TopoDocument) async {
    nonisolated(unsafe) let closing = document
    _ = await closing.close()
}

@MainActor
func autosaveForTest(_ document: TopoDocument) async -> Bool {
    nonisolated(unsafe) let saving = document
    return await saving.autosave()
}

import Foundation
@testable import CyberTopology

// Test-side names for the document lifecycle. These now just forward to
// TopoDocument's own main-actor wrappers (see "Main-actor lifecycle" there):
// awaiting UIDocument's nonisolated async open/close/autosave from MainActor
// test code sent the non-Sendable document across an isolation boundary, which
// the Xcode 26.6 compiler rejects. The wrappers bridge UIKit's synchronous
// completion-handler API instead, so no nonisolated(unsafe) contract is needed
// here any more.

@MainActor
func openForTest(_ document: TopoDocument) async -> Bool {
    await document.openForEditing()
}

@MainActor
func closeDocument(_ document: TopoDocument) async {
    _ = await document.closeSavingChanges()
}

@MainActor
func autosaveForTest(_ document: TopoDocument) async -> Bool {
    await document.autosaveChanges()
}

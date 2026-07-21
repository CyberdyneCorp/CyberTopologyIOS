import SwiftUI

@main
struct CyberTopologyApp: App {
    init() {
        UITestSupport.resetStateIfRequested(arguments: ProcessInfo.processInfo.arguments)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// UI-test hooks. `-UITestResetState` gives each UI test a clean slate:
/// no recovery journal and no leftover documents. `-UITestOpenDocument`
/// opens (creating if needed) a fixed document at launch, bypassing the
/// system browser chrome, which hides custom bar buttons in an overflow
/// menu on some iPadOS versions and is too fragile to drive from XCUITest.
enum UITestSupport {
    static let resetArgument = "-UITestResetState"
    static let openDocumentArgument = "-UITestOpenDocument"

    static var openDocumentRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(openDocumentArgument)
    }

    /// Fixed URL for the auto-opened test document.
    static var testDocumentURL: URL {
        URL.documentsDirectory
            .appendingPathComponent("UITest Document")
            .appendingPathExtension(TopoDocument.fileExtension)
    }

    static func resetStateIfRequested(
        arguments: [String],
        journalURL: URL = RecoveryJournal.defaultStoreURL(),
        documentsDirectory: URL = .documentsDirectory
    ) {
        guard arguments.contains(resetArgument) else { return }
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: journalURL)
        let contents = (try? fileManager.contentsOfDirectory(
            at: documentsDirectory, includingPropertiesForKeys: nil
        )) ?? []
        for url in contents where url.pathExtension == TopoDocument.fileExtension {
            try? fileManager.removeItem(at: url)
        }
    }
}

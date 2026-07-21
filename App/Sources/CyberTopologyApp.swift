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
    /// With `openDocumentArgument`: imports a small EditMesh into the test
    /// document so object-list / export flows are drivable from XCUITest
    /// (the Files picker is system UI and cannot be automated).
    static let seedEditMeshArgument = "-UITestSeedEditMesh"

    static var openDocumentRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(openDocumentArgument)
    }

    static var seedEditMeshRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(seedEditMeshArgument)
    }

    /// Minimal colored quad used by the seed hook.
    static func writeSeedOBJ() throws -> URL {
        let obj = """
        v 0 0 0 1 0 0
        v 1 0 0 0 1 0
        v 1 1 0 0 0 1
        v 0 1 0 1 1 1
        f 1 2 3 4
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("seed-quad.obj")
        try obj.write(to: url, atomically: true, encoding: .utf8)
        return url
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

import XCTest

final class CyberTopologyUITests: XCTestCase {
    private func launch(arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return app
    }

    /// Spec: document-model / "Files app visibility" (browser entry point).
    /// The system document browser is the root screen. Its chrome varies by
    /// iPadOS version, so assert on the stable tab labels.
    @MainActor
    func testAppLaunchesIntoDocumentBrowser() throws {
        let app = launch(arguments: ["-UITestResetState"])
        XCTAssertTrue(app.buttons["Recents"].waitForExistence(timeout: 10)
            || app.staticTexts["Recents"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Browse"].exists || app.staticTexts["Browse"].exists)
    }

    /// Spec: document-model / "Free-tier save" + editor round trip: open a
    /// document, verify the editor shows it with the engine bridged, close
    /// back to the browser.
    @MainActor
    func testOpenAndCloseDocument() throws {
        let app = launch(arguments: ["-UITestResetState", "-UITestOpenDocument"])

        let name = app.staticTexts["document-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 15))
        XCTAssertEqual(name.label, "UITest Document")
        // Type-agnostic query: the placeholder overlay does not expose the
        // version Text as a staticText on all iPadOS versions.
        let version = app.descendants(matching: .any)["engine-version"].firstMatch
        XCTAssertTrue(version.waitForExistence(timeout: 10))
        XCTAssertTrue(version.label.hasPrefix("Engine "))

        app.buttons["close-document"].tap()
        XCTAssertTrue(app.buttons["Recents"].waitForExistence(timeout: 10)
            || app.staticTexts["No Recents"].waitForExistence(timeout: 5))
    }

    /// Spec: document-model / "Stage state round-trip" (UI slice): a stage
    /// edit survives closing the document and relaunching the app.
    @MainActor
    func testStageEditSurvivesRelaunch() throws {
        let app = launch(arguments: ["-UITestResetState", "-UITestOpenDocument"])

        let picker = app.segmentedControls["stage-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 15))
        picker.buttons["UV"].tap()
        app.buttons["close-document"].tap()
        XCTAssertTrue(app.buttons["Recents"].waitForExistence(timeout: 10))
        app.terminate()

        // Relaunch WITHOUT reset: the same document reopens from disk.
        let relaunched = launch(arguments: ["-UITestOpenDocument"])
        let reopenedPicker = relaunched.segmentedControls["stage-picker"]
        XCTAssertTrue(reopenedPicker.waitForExistence(timeout: 15))
        XCTAssertTrue(reopenedPicker.buttons["UV"].isSelected)
    }

    /// Spec: document-model / "Save new version": creates a named sibling
    /// copy while the original stays open.
    @MainActor
    func testSaveNewVersion() throws {
        let app = launch(arguments: ["-UITestResetState", "-UITestOpenDocument"])

        let save = app.buttons["save-version"]
        XCTAssertTrue(save.waitForExistence(timeout: 15))
        save.tap()

        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Milestone")
        app.buttons["Save"].tap()

        // Original document is still open in the editor.
        XCTAssertEqual(app.staticTexts["document-name"].label, "UITest Document")
    }
}

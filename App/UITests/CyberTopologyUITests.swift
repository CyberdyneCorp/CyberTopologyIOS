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

    /// Spec: document-model / "Gesture undo/redo": two-finger tap undoes,
    /// three-finger tap redoes; toolbar buttons mirror journal state.
    @MainActor
    func testUndoRedoGesturesAndButtons() throws {
        let app = launch(arguments: ["-UITestResetState", "-UITestOpenDocument"])

        let picker = app.segmentedControls["stage-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["undo"].isEnabled)

        picker.buttons["UV"].tap()
        XCTAssertTrue(app.buttons["undo"].isEnabled)

        let viewport = app.otherElements["viewport-placeholder"].firstMatch
        let target = viewport.exists ? viewport : app.windows.firstMatch

        target.twoFingerTap()
        XCTAssertTrue(picker.buttons["RT"].isSelected)
        XCTAssertTrue(app.buttons["redo"].isEnabled)

        target.tap(withNumberOfTaps: 1, numberOfTouches: 3)
        XCTAssertTrue(picker.buttons["UV"].isSelected)
        XCTAssertFalse(app.buttons["redo"].isEnabled)
    }

    /// Object list + export flow on a seeded EditMesh (task 1.5): the object
    /// row shows counts, and Export EditMeshes reports success.
    @MainActor
    func testSeededObjectListAndExport() throws {
        let app = launch(arguments: [
            "-UITestResetState", "-UITestOpenDocument", "-UITestSeedEditMesh",
        ])

        let row = app.descendants(matching: .any)["object-row-seed-quad"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))

        app.buttons["io-menu"].tap()
        let export = app.buttons["export-editmeshes"]
        XCTAssertTrue(export.waitForExistence(timeout: 5))
        export.tap()

        let status = app.staticTexts["status-message"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertTrue(status.label.hasPrefix("Exported"))
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

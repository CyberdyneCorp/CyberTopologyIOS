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

        let viewport = app.otherElements["viewport"].firstMatch
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

    /// Gesture arbitration (spec: viewport-rendering / "Robust camera
    /// system"): camera drags/pinches/double-taps on the viewport must not
    /// fire undo/redo, and the multi-finger taps must keep working after
    /// camera gestures.
    @MainActor
    func testCameraGesturesDoNotConflictWithUndoTaps() throws {
        let app = launch(arguments: [
            "-UITestResetState", "-UITestOpenDocument", "-UITestSeedEditMesh",
        ])

        let picker = app.segmentedControls["stage-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 15))
        picker.buttons["UV"].tap()  // one undoable command
        XCTAssertTrue(app.buttons["undo"].isEnabled)

        let viewport = app.otherElements["viewport"].firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))

        viewport.swipeLeft()  // orbit drag
        viewport.pinch(withScale: 1.6, velocity: 1.0)  // zoom
        viewport.doubleTap()  // reframe-to-fit

        // None of the camera gestures may have walked the undo journal.
        XCTAssertTrue(picker.buttons["UV"].isSelected)
        XCTAssertTrue(app.buttons["undo"].isEnabled)
        XCTAssertFalse(app.buttons["redo"].isEnabled)

        // Multi-finger taps still arbitrate correctly after camera gestures.
        viewport.twoFingerTap()
        XCTAssertTrue(picker.buttons["RT"].isSelected)
        viewport.tap(withNumberOfTaps: 1, numberOfTouches: 3)
        XCTAssertTrue(picker.buttons["UV"].isSelected)
    }

    /// Adjustable orbit/zoom speed (spec: viewport-rendering): the settings
    /// popover exposes both sliders and a reset.
    @MainActor
    func testViewportSettingsPopover() throws {
        let app = launch(arguments: ["-UITestResetState", "-UITestOpenDocument"])

        let settings = app.buttons["viewport-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        settings.tap()

        let orbitSlider = app.sliders["orbit-speed-slider"]
        XCTAssertTrue(orbitSlider.waitForExistence(timeout: 5))
        XCTAssertTrue(app.sliders["zoom-speed-slider"].exists)

        // EditMesh overlay options (task 2.3): wireframe opacity, occlusion
        // depth threshold, and the x-ray toggle.
        XCTAssertTrue(app.sliders["wireframe-opacity-slider"].exists)
        XCTAssertTrue(app.sliders["occlusion-depth-slider"].exists)
        let xray = app.switches["xray-toggle"]
        XCTAssertTrue(xray.exists)
        xray.switches.firstMatch.tap()

        // Performance controls (task 2.5): resolution scale segmented
        // picker; switch to 50% and back to 100% so persisted defaults stay
        // clean for other tests.
        let resolution = app.segmentedControls["resolution-scale-picker"]
        XCTAssertTrue(resolution.exists)
        resolution.buttons["50%"].tap()
        XCTAssertTrue(resolution.buttons["50%"].isSelected)
        resolution.buttons["100%"].tap()

        // DEBUG-only ghost preview toggle (task 2.4 demo path; UI tests run
        // Debug builds). Toggle on and back off so persisted defaults stay
        // clean for other tests.
        let ghost = app.switches["ghost-debug-toggle"]
        XCTAssertTrue(ghost.exists)
        ghost.switches.firstMatch.tap()
        ghost.switches.firstMatch.tap()

        orbitSlider.adjust(toNormalizedSliderPosition: 0.9)
        app.buttons["reset-camera-speeds"].tap()
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

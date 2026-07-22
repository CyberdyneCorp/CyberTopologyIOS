import XCTest

/// Customizable toolbar + Action Gallery (task 3.8, spec:
/// pencil-interaction / "Customizable toolbar and Action Gallery").
///
/// XCUITest cannot synthesize drag-and-drop between SwiftUI drop
/// destinations (press-and-drag never lifts the item into a drag
/// session reliably on the simulator), so these tests exercise the
/// TAP-based assignment path — which routes into the exact same
/// `ToolbarModel` mutations as the drag handlers; the drag payload/drop
/// policy itself is unit-covered headless (`ToolbarConfigurationTests`).
final class ActionGalleryUITests: XCTestCase {
    /// Every action id the gallery must list (verbs + the 3.4 grammar) —
    /// mirrored from `EditorAction` (UI tests cannot import app code).
    private static let allActionIDs = [
        "pencil", "relax", "move", "tweak", "erase",
        "quadDraw", "gridStroke", "loopInsert", "loopTag",
        "scribbleDissolve", "crossDelete", "mergeLine", "edgeRotate",
        "doubleTapTweak", "visibilityLasso", "visibilityLines",
    ]

    private func launch(arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return app
    }

    /// Polls a condition (UI updates after taps land through async SwiftUI
    /// passes; tile selection in particular fires a beat late because the
    /// single-tap gesture waits out the double-tap window).
    @MainActor
    @discardableResult
    private func waitUntil(
        timeout: TimeInterval = 5, _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        }
        return condition()
    }

    /// Taps an action tile and waits for the selection to land.
    @MainActor
    private func selectTile(_ app: XCUIApplication, _ id: String) {
        let tile = app.descendants(matching: .any)["gallery-action-\(id)"].firstMatch
        tile.tap()
        XCTAssertTrue(
            waitUntil { tile.value as? String == "selected" },
            "tile \(id) did not become selected"
        )
    }

    @MainActor
    private func openGallery(_ app: XCUIApplication) {
        let button = app.buttons["action-gallery-button"]
        XCTAssertTrue(button.waitForExistence(timeout: 15))
        button.tap()
        XCTAssertTrue(
            app.staticTexts["gallery-help-title"].waitForExistence(timeout: 10)
        )
    }

    /// The gallery lists EVERY action, and selecting one fills the help
    /// panel: title, gesture line, usage notes, and the demo-media slot
    /// (the honestly-labeled placeholder until the 9.1 recordings).
    @MainActor
    func testGalleryListsEveryActionWithHelpPanel() throws {
        let app = launch(arguments: ["-UITestResetState", "-UITestOpenDocument"])
        openGallery(app)

        // One predicate query instead of a per-action descendants sweep:
        // on slow CI hierarchies each any-type query can hit XCUITest's
        // evaluation timeout ("Timed out while evaluating UI query").
        let rows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'gallery-action-'")
        )
        let found = Set(rows.allElementsBoundByIndex.map(\.identifier))
        for id in Self.allActionIDs {
            XCTAssertTrue(found.contains("gallery-action-\(id)"),
                          "gallery is missing action \(id)")
        }

        // Select a grammar action: the help panel switches to it.
        selectTile(app, "loopInsert")
        let title = app.staticTexts["gallery-help-title"]
        XCTAssertTrue(
            waitUntil { title.label == "Insert loop" }, "title: \(title.label)"
        )
        XCTAssertFalse(app.staticTexts["gallery-help-gesture"].label.isEmpty)
        XCTAssertFalse(app.staticTexts["gallery-help-notes"].label.isEmpty)
        XCTAssertTrue(app.staticTexts["gallery-demo-placeholder"].exists)

        // Visual record of the gallery + help panel.
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "action-gallery"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Tapping a gesture-action slot on the LIVE toolbar opens the
    /// gallery focused on that action's help panel.
    @MainActor
    func testToolbarGestureSlotOpensGalleryFocused() throws {
        let app = launch(arguments: ["-UITestResetState", "-UITestOpenDocument"])
        openGallery(app)

        // Put a gesture action into the empty slot via the tap path.
        selectTile(app, "edgeRotate")
        app.buttons["gallery-slot-5"].tap()
        app.buttons["gallery-done"].tap()

        let slotButton = app.buttons["toolbar-action-edgeRotate"]
        XCTAssertTrue(slotButton.waitForExistence(timeout: 5))
        slotButton.tap()

        let title = app.staticTexts["gallery-help-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertTrue(
            waitUntil { title.label == "Rotate edge" }, "title: \(title.label)"
        )
    }

    /// The full customization loop on the slot editor — quick-assign
    /// (double-tap), tap-assign into a chosen slot, replace, remove — and
    /// the spec scenario "Toolbar persistence": the customized toolbar is
    /// restored EXACTLY after a relaunch without the reset argument.
    @MainActor
    func testAssignReplaceRemovePersistAcrossRelaunch() throws {
        let app = launch(arguments: ["-UITestResetState", "-UITestOpenDocument"])

        // Default layout: five verb slots + one empty slot on the live
        // toolbar (the hosted 3.1 verb bar).
        XCTAssertTrue(
            app.descendants(matching: .any)["verb-pencil"].firstMatch
                .waitForExistence(timeout: 15)
        )
        XCTAssertTrue(app.buttons["toolbar-slot-empty-5"].exists)

        openGallery(app)
        let slot5 = app.buttons["gallery-slot-5"]
        XCTAssertEqual(slot5.value as? String, "empty")

        // QUICK-ASSIGN: double-tap goes to the first empty slot.
        app.descendants(matching: .any)["gallery-action-loopTag"].firstMatch.doubleTap()
        XCTAssertTrue(waitUntil { slot5.value as? String == "loopTag" })

        // REPLACE: selecting another action and tapping the occupied slot
        // overwrites it.
        selectTile(app, "loopInsert")
        slot5.tap()
        XCTAssertTrue(waitUntil { slot5.value as? String == "loopInsert" })

        // REMOVE: the slot's remove affordance empties it.
        app.buttons["gallery-slot-remove-5"].tap()
        XCTAssertTrue(waitUntil { slot5.value as? String == "empty" })

        // Final layout for the persistence check: assign again via the
        // tap path (the selection is still Insert loop).
        slot5.tap()
        XCTAssertTrue(waitUntil { slot5.value as? String == "loopInsert" })
        app.buttons["gallery-done"].tap()

        // The live toolbar hosts the new slot next to the verbs.
        XCTAssertTrue(app.buttons["toolbar-action-loopInsert"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["verb-erase"].firstMatch.exists)

        // RELAUNCH without reset: the customized toolbar is restored
        // exactly — the custom slot AND the verb slots.
        app.terminate()
        let relaunched = launch(arguments: ["-UITestOpenDocument"])
        XCTAssertTrue(
            relaunched.buttons["toolbar-action-loopInsert"].waitForExistence(timeout: 15)
        )
        XCTAssertTrue(
            relaunched.descendants(matching: .any)["verb-pencil"].firstMatch.exists
        )
        XCTAssertFalse(relaunched.buttons["toolbar-slot-empty-5"].exists)

        // And the restored slot still opens its help panel (config maps
        // to real catalog entries, not just an icon).
        relaunched.buttons["toolbar-action-loopInsert"].tap()
        let title = relaunched.staticTexts["gallery-help-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertTrue(
            waitUntil { title.label == "Insert loop" }, "title: \(title.label)"
        )
    }
}

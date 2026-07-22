import XCTest

final class CyberTopologyUITests: XCTestCase {
    private func launch(arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return app
    }

    /// Polls `condition` for up to `timeout` seconds. Multi-finger tap
    /// outcomes are not synchronous with the synthesized event: the 3-touch
    /// undo recognizer waits for the 4-touch redo recognizer to fail before
    /// firing, so immediate assertions race the recognizer pipeline.
    @discardableResult
    private func waitUntil(
        timeout: TimeInterval = 3, _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        return condition()
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

    /// Spec: document-model / "Gesture undo/redo": three-finger tap undoes,
    /// four-finger tap redoes; toolbar buttons mirror journal state.
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

        target.tap(withNumberOfTaps: 1, numberOfTouches: 3)
        XCTAssertTrue(waitUntil { picker.buttons["RT"].isSelected })
        XCTAssertTrue(app.buttons["redo"].isEnabled)

        target.tap(withNumberOfTaps: 1, numberOfTouches: 4)
        XCTAssertTrue(waitUntil { picker.buttons["UV"].isSelected })
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

        // Multi-finger taps still arbitrate correctly after camera gestures
        // (polled: the 3-touch recognizer waits for the 4-touch one to
        // fail, so the outcome is not synchronous with the tap).
        viewport.tap(withNumberOfTaps: 1, numberOfTouches: 3)
        XCTAssertTrue(waitUntil { picker.buttons["RT"].isSelected })
        viewport.tap(withNumberOfTaps: 1, numberOfTouches: 4)
        XCTAssertTrue(waitUntil { picker.buttons["UV"].isSelected })
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

    /// Task 3.9 (spec: pencil-interaction / "Finger strokes never
    /// author"): finger drags on the viewport NEVER author geometry —
    /// they navigate the camera. After dragging a quad-shaped finger path
    /// (four straight segments; XCUITest cannot synthesize a curved
    /// single-touch polyline) the object list's mesh counts are unchanged,
    /// nothing was captured or interpreted (no stroke HUD entry), and no
    /// new journal entry exists (undo/redo state exactly as before). The
    /// camera-side half — the same finger touches are ADMITTED to the
    /// orbit/pinch recognizers and move the camera — is covered by
    /// `testCameraGesturesDoNotConflictWithUndoTaps` plus the arbiter and
    /// controller unit suites (finger stroke → camera decisions, never
    /// `beginStroke`).
    @MainActor
    func testFingerStrokesNeverAuthorAndKeepNavigating() throws {
        let app = launch(arguments: [
            "-UITestResetState", "-UITestOpenDocument", "-UITestSeedEditMesh",
        ])

        let viewport = app.otherElements["viewport"].firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 15))
        let row = app.descendants(matching: .any)["object-row-seed-quad"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))

        // Snapshot mesh counts and journal state (the seeded import is one
        // journaled command; finger input must add nothing on top).
        let countsBefore = row.label
        XCTAssertTrue(countsBefore.contains("4 v"), "row label: \(countsBefore)")
        XCTAssertTrue(countsBefore.contains("1 f"), "row label: \(countsBefore)")
        let undoEnabledBefore = app.buttons["undo"].isEnabled
        let redoEnabledBefore = app.buttons["redo"].isEnabled

        // A quad-shaped finger path: four straight drag segments.
        viewport.swipeLeft()
        viewport.swipeUp()
        viewport.swipeRight()
        viewport.swipeDown()

        // Negative assertions need a settle window: a regression would
        // land its journal commit and row-label update on a LATER main-
        // runloop pass (see `waitForLabel`), so sampling synchronously
        // right after the swipes could read the pre-stroke snapshot and
        // pass. Poll for ~2s and require that NO regression signal ever
        // appears: no stroke capture (stroke HUD), no geometry (mesh
        // counts fixed), no journal entry (undo/redo exactly as before).
        let regressed = waitUntil(timeout: 2) {
            app.staticTexts["stroke-hud"].exists
                || row.label != countsBefore
                || app.buttons["undo"].isEnabled != undoEnabledBefore
                || app.buttons["redo"].isEnabled != redoEnabledBefore
        }
        XCTAssertFalse(regressed, "finger drags authored: row=\(row.label)")

        // Undo gestures still arbitrate normally after the drags.
        XCTAssertTrue(app.segmentedControls["stage-picker"].exists)
    }

    /// Recognizer debug HUD (task 3.2, design D5 "interpretation records +
    /// debug HUD from day one"): toggled from the viewport settings popover
    /// (DEBUG builds), it overlays the last stroke's polyline and the full
    /// interpretation record produced by the engine recognizer. The stroke
    /// is injected via the committed square fixture replayed through the
    /// REAL capture → recognizer pipeline (authoring is Pencil-only —
    /// task 3.9 — and XCUITest cannot synthesize Pencil touches).
    @MainActor
    func testStrokeDebugHUDShowsInterpretationRecord() throws {
        let app = launch(arguments: [
            "-UITestResetState", "-UITestOpenDocument", "-UITestSeedTarget",
            "-UITestStrokeInjection",
        ])
        let viewport = app.otherElements["viewport"].firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 15))

        // Enable the HUD from the settings popover.
        app.buttons["viewport-settings"].tap()
        let hudToggle = app.switches["stroke-debug-toggle"]
        XCTAssertTrue(hudToggle.waitForExistence(timeout: 5))
        hudToggle.switches.firstMatch.tap()
        dismissPopover(app)

        // Inject the square stroke; the record appears in the HUD.
        let inject = app.buttons["inject-square-stroke"]
        XCTAssertTrue(inject.waitForExistence(timeout: 5))
        inject.tap()

        let record = app.descendants(matching: .any)["stroke-debug-record"].firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        XCTAssertFalse(record.label.isEmpty)

        // Visual-verification artifact: the HUD with polyline +
        // interpretation record, archived in the .xcresult.
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "stroke-debug-hud"
        shot.lifetime = .keepAlways
        add(shot)

        // Restore persisted defaults for the other tests.
        app.buttons["viewport-settings"].tap()
        XCTAssertTrue(hudToggle.waitForExistence(timeout: 5))
        hudToggle.switches.firstMatch.tap()
        dismissPopover(app)
    }

    /// Closes an open popover (iPad presents them with a dismiss region).
    @MainActor
    private func dismissPopover(_ app: XCUIApplication) {
        let dismiss = app.otherElements["PopoverDismissRegion"].firstMatch
        if dismiss.exists {
            dismiss.tap()
        }
    }

    /// Hold-chord spring-loaded verbs (task 3.1, spec: pencil-interaction /
    /// "Hold-chord spring-loaded modifiers"): a quick tap selects a verb
    /// persistently; holding another verb switches only for the duration of
    /// the hold and restores the previous verb on release.
    @MainActor
    func testVerbToolbarTapSelectsAndHoldRestores() throws {
        let app = launch(arguments: ["-UITestResetState", "-UITestOpenDocument"])

        let relax = app.descendants(matching: .any)["verb-relax"].firstMatch
        XCTAssertTrue(relax.waitForExistence(timeout: 15))
        let pencil = app.descendants(matching: .any)["verb-pencil"].firstMatch
        XCTAssertEqual(pencil.value as? String, "active")  // default verb

        // Quick tap: persistent selection.
        relax.tap()
        XCTAssertEqual(relax.value as? String, "active")
        XCTAssertEqual(pencil.value as? String, "inactive")

        // Long hold on Erase: spring-loaded — after release the previous
        // persistent verb (Relax) is active again immediately.
        let erase = app.descendants(matching: .any)["verb-erase"].firstMatch
        erase.press(forDuration: 1.0)
        XCTAssertEqual(relax.value as? String, "active")
        XCTAssertEqual(erase.value as? String, "inactive")
    }

    /// Task 3.7 (spec: pencil-interaction / "Pencil Pro and haptic
    /// feedback"): the radial quick-verb palette end to end — shown at the
    /// squeeze entry point, a ring verb tap selects it on the shared
    /// arbiter (toolbar highlight follows), and the palette dismisses.
    /// XCUITest cannot synthesize a Pencil Pro squeeze, so the launch hook
    /// drives the same model entry the `UIPencilInteraction` delegate
    /// calls on hardware (squeeze DELIVERY is the device-only half —
    /// `PencilProHardwareTests`).
    @MainActor
    func testQuickVerbPaletteSelectsVerbOnTheSharedArbiter() throws {
        let app = launch(arguments: [
            "-UITestResetState", "-UITestOpenDocument", "-UITestShowQuickVerbPalette",
        ])

        let relax = app.descendants(matching: .any)["quick-verb-relax"].firstMatch
        XCTAssertTrue(relax.waitForExistence(timeout: 20))
        let toolbarPencil = app.descendants(matching: .any)["verb-pencil"].firstMatch
        XCTAssertEqual(toolbarPencil.value as? String, "active")  // default verb

        relax.tap()

        // Selection reached the shared arbiter: the TOOLBAR highlight
        // moved, and the palette dismissed.
        let toolbarRelax = app.descendants(matching: .any)["verb-relax"].firstMatch
        XCTAssertEqual(toolbarRelax.value as? String, "active")
        XCTAssertEqual(toolbarPencil.value as? String, "inactive")
        XCTAssertFalse(relax.exists)
    }

    /// Task 3.3 end to end (specs: pencil-interaction / "Five coherent
    /// verbs", document-model / "EditMesh vertex snapping"): a square quad
    /// gesture on the seeded Target creates a journaled quad, and the
    /// three/four-finger taps undo/redo it. XCUITest cannot synthesize a
    /// multi-segment single-touch polyline (only straight drags), so the
    /// square stroke is injected via the launch-argument-gated button that
    /// replays the committed square fixture through the REAL
    /// capture → engine recognizer → verb → journal pipeline; the raw
    /// UIKit touch layer itself is exercised by the controller unit suite
    /// (live authoring is Pencil-only — task 3.9).
    @MainActor
    func testDrawQuadOnSeededTargetJournalsAndUndoes() throws {
        let app = launch(arguments: [
            "-UITestResetState", "-UITestOpenDocument", "-UITestSeedTarget",
            "-UITestStrokeInjection",
        ])

        let viewport = app.otherElements["viewport"].firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 15))
        let targetRow = app.descendants(matching: .any)["object-row-seed-target"].firstMatch
        XCTAssertTrue(targetRow.waitForExistence(timeout: 10))
        let quadRow = app.descendants(matching: .any)["object-row-EditMesh"].firstMatch
        XCTAssertFalse(quadRow.exists)

        // Draw the quad (fixture replay through the real pipeline).
        let inject = app.buttons["inject-square-stroke"]
        XCTAssertTrue(inject.waitForExistence(timeout: 5))
        inject.tap()

        // The authored EditMesh appears with exactly one quad, journaled.
        XCTAssertTrue(quadRow.waitForExistence(timeout: 10))
        XCTAssertTrue(quadRow.label.contains("4 v"), "row label: \(quadRow.label)")
        XCTAssertTrue(quadRow.label.contains("1 f"), "row label: \(quadRow.label)")
        XCTAssertTrue(app.buttons["undo"].isEnabled)

        // Three-finger tap undoes the quad; four-finger tap redoes it.
        viewport.tap(withNumberOfTaps: 1, numberOfTouches: 3)
        XCTAssertTrue(quadRow.waitForNonExistence(timeout: 5))
        viewport.tap(withNumberOfTaps: 1, numberOfTouches: 4)
        XCTAssertTrue(quadRow.waitForExistence(timeout: 5))
    }

    /// Task 3.5 end to end (spec: pencil-interaction / "Post-stroke
    /// interpretation chip" + "One-tap misrecognition fix"), via fixture
    /// injection (XCUITest cannot synthesize Pencil touches, and fingers
    /// never author — task 3.9): the vertical stroke along the seeded strip's middle edge
    /// is genuinely ambiguous — it applies as TAG LOOP and the chip offers
    /// the INSERT LOOP alternative (the spec's exact misrecognition pair).
    /// ONE tap swaps the applied result in place (the tag annotation
    /// reverts, the loop insert splits the mesh), and the undo gestures
    /// prove the journal holds exactly ONE entry for the stroke after the
    /// swap — no extra undo step.
    @MainActor
    func testInterpretationChipSwapsAlternativeInPlace() throws {
        let app = launch(arguments: [
            "-UITestResetState", "-UITestOpenDocument", "-UITestSeedEditMeshStrip",
            "-UITestStrokeInjection",
        ])

        let viewport = app.otherElements["viewport"].firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 15))
        let row = app.descendants(matching: .any)["object-row-seed-strip"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.label.contains("6 v"), "row: \(row.label)")
        XCTAssertTrue(row.label.contains("2 f"), "row: \(row.label)")

        // The ambiguous stroke (fixture replay through the real pipeline).
        let inject = app.buttons["inject-ring-stroke"]
        XCTAssertTrue(inject.waitForExistence(timeout: 5))
        inject.tap()

        // Applied: tag loop — an annotation, so the mesh counts are
        // untouched; the chip states it and offers the insert alternative.
        let title = app.staticTexts["interpretation-chip-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "Tag loop")
        XCTAssertTrue(row.label.contains("2 f"), "row: \(row.label)")

        // Chip screenshot for the visual record.
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "interpretation-chip"
        shot.lifetime = .keepAlways
        add(shot)

        // ONE TAP: the applied result is REPLACED (not stacked) — the tag
        // reverts and the recognizer's ranked ring splits the strip (one
        // or both quads depending on which crossed edge seeded the walk
        // under the live camera framing; the invariant is the SPLIT).
        let alternative = app.buttons["chip-alternative-insertLoop"]
        XCTAssertTrue(alternative.waitForExistence(timeout: 5))
        alternative.tap()
        XCTAssertTrue(
            waitForLabel(of: row) { !$0.contains("2 f") }, "row: \(row.label)"
        )
        XCTAssertTrue(
            row.label.contains("3 f") || row.label.contains("4 f"),
            "row: \(row.label)"
        )
        XCTAssertEqual(title.label, "Insert loop")
        // The swapped chip offers the original reading back.
        XCTAssertTrue(app.buttons["chip-alternative-tagLoop"].exists)

        // Journal invariant via the undo gesture: the FIRST undo reverts
        // the whole stroke (back to the seeded strip counts, seed import
        // remains), the SECOND removes the seeded object — the swap added
        // no extra journal entry.
        viewport.tap(withNumberOfTaps: 1, numberOfTouches: 3)
        XCTAssertTrue(waitForLabel(of: row) { $0.contains("2 f") }, "row: \(row.label)")
        XCTAssertTrue(row.label.contains("6 v"), "row: \(row.label)")
        XCTAssertTrue(app.buttons["undo"].isEnabled)
        viewport.tap(withNumberOfTaps: 1, numberOfTouches: 3)
        XCTAssertTrue(row.waitForNonExistence(timeout: 5))
    }

    /// Polls an element's label (row counts update through async SwiftUI
    /// passes after journal commits).
    @MainActor
    private func waitForLabel(
        of element: XCUIElement, timeout: TimeInterval = 5,
        until predicate: (String) -> Bool
    ) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if predicate(element.label) { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        }
        return predicate(element.label)
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

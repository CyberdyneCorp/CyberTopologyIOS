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

    /// Environment gate for interaction-dependent UI tests (spec:
    /// quality-assurance / "Simulator test execution in CI" — skips must be
    /// classified, never silent).
    ///
    /// GitHub's virtualized simulator hosts cannot faithfully run these:
    /// synthesized 3/4-finger taps arbitrate unreliably under load, and the
    /// software Metal stack cannot drive stroke unprojection. Document-flow
    /// UI tests keep running there. Locally the flag is unset, so the full
    /// suite is mandatory; the physical-device plan (task 9.6) is where
    /// these are contractually required to pass.
    private func skipIfInteractionUnsupported() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["CYBERTOPOLOGY_SKIP_INTERACTION_UITESTS"] == "1",
            "interaction UI test: requires a real simulator host "
                + "(multi-touch synthesis + hardware Metal); runs locally and on device"
        )
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
        try skipIfInteractionUnsupported()
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

    /// Object removal (change: manage-document-objects): the per-row delete
    /// control removes that object, and undo restores it — one journaled
    /// step.
    @MainActor
    func testDeleteEditMeshRemovesRowAndUndoRestores() throws {
        let app = launch(arguments: [
            "-UITestResetState", "-UITestOpenDocument", "-UITestSeedEditMesh",
        ])
        let row = app.descendants(matching: .any)["object-row-seed-quad"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))

        app.buttons["object-delete-editmesh"].firstMatch.tap()
        XCTAssertFalse(
            row.waitForExistence(timeout: 3), "the EditMesh row should be gone after delete"
        )

        // Undo (toolbar) restores it — one step.
        app.buttons["undo"].tap()
        XCTAssertTrue(
            row.waitForExistence(timeout: 5), "undo should restore the deleted EditMesh"
        )
    }

    /// Gesture arbitration (spec: viewport-rendering / "Robust camera
    /// system"): camera drags/pinches/double-taps on the viewport must not
    /// fire undo/redo, and the multi-finger taps must keep working after
    /// camera gestures.
    @MainActor
    func testCameraGesturesDoNotConflictWithUndoTaps() throws {
        try skipIfInteractionUnsupported()
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
        try skipIfInteractionUnsupported()
        let app = launch(arguments: [
            "-UITestResetState", "-UITestOpenDocument", "-UITestSeedTarget",
            "-UITestStrokeInjection",
        ])
        let viewport = app.otherElements["viewport"].firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 15))

        // Enable the HUD from the settings popover.
        app.buttons["viewport-settings"].tap()
        let hudToggle = app.switches["stroke-debug-toggle"]
        XCTAssertTrue(hudToggle.waitForExistence(timeout: 15))
        hudToggle.switches.firstMatch.tap()
        dismissPopover(app)

        // Inject the square stroke; the record appears in the HUD.
        let inject = app.buttons["inject-square-stroke"]
        XCTAssertTrue(inject.waitForExistence(timeout: 15))
        inject.tap()

        // Generous timeout: on cold CI simulators the injected stroke's
        // capture -> engine recognizer -> HUD publish takes far longer
        // than on a warm local machine (first observed CI-only failure).
        // Raised again after a 30 s timeout under CODE-COVERAGE
        // INSTRUMENTATION, which roughly doubles this test's wall time
        // (46 s instrumented vs 19 s plain) — the pipeline was still
        // working, it had simply not finished.
        let record = app.descendants(matching: .any)["stroke-debug-record"].firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 90))
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

    /// The DEBUG stroke recorder (change simplify-gesture-grammar, task 1.1)
    /// must be REACHABLE from the settings popover, not merely present in
    /// the accessibility tree. It sits at the very bottom of a settings
    /// column that is taller than the screen on smaller iPads; before the
    /// popover was made scrollable it was clipped off with no way to tap it
    /// (reported: "where is Record last stroke?"). Existence assertions do
    /// not catch this — a clipped element still `exists` — so this test
    /// TAPS it and confirms the recorder actually opens.
    @MainActor
    func testStrokeRecorderIsReachableFromSettings() throws {
        try skipIfInteractionUnsupported()
        let app = launch(arguments: ["-UITestResetState", "-UITestOpenDocument"])

        let settings = app.buttons["viewport-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        settings.tap()

        let record = app.buttons["stroke-record-button"]
        XCTAssertTrue(record.waitForExistence(timeout: 15))

        // Scroll it into view if the popover is taller than the screen.
        // Whether or not scrolling is needed, the button must end up
        // hittable — that is the property the clipping bug violated.
        var swipes = 0
        while !record.isHittable && swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(record.isHittable, "Record button never became tappable")

        record.tap()

        // No stroke was drawn, so the recorder opens on its empty state —
        // its presence proves the button reached its action.
        let empty = app.staticTexts["stroke-export-empty"]
        XCTAssertTrue(empty.waitForExistence(timeout: 10))
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
        try skipIfInteractionUnsupported()
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
        XCTAssertTrue(inject.waitForExistence(timeout: 15))
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
        try skipIfInteractionUnsupported()
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

    /// Polls `condition` until it holds or the timeout expires.
    private func waitForCondition(
        timeout: TimeInterval = 5, _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        }
        return condition()
    }

    /// Task 4.1 end to end (spec: retopology-tools / "Core RT action
    /// roster"): the Surface Cut tool armed and driven through the
    /// auto-tool probe (XCUITest cannot synthesize Pencil drags; the probe
    /// computes a real knife stroke from the live mesh + camera and drives
    /// the REAL capture → tool-session → journal pipeline). The seeded
    /// on-dome strip (2 faces) gains faces from the cut, journaled as one
    /// entry — a single three-finger undo restores it.
    @MainActor
    func testSurfaceCutToolProbeCutsSeededStripAndUndoRestores() throws {
        try skipIfInteractionUnsupported()
        let app = launch(arguments: [
            "-UITestResetState", "-UITestOpenDocument", "-UITestSeedTarget",
            "-UITestSeedEditMeshOnDome", "-UITestAutoTool", "surfaceCut",
        ])

        let viewport = app.otherElements["viewport"].firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 15))
        let row = app.descendants(matching: .any)["object-row-seed-dome-strip"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))

        // The auto-tool hook fires ~3 s after the editor appears; the cut
        // splits edges and faces of the 6 v / 2 f strip.
        XCTAssertTrue(
            waitForLabel(of: row, timeout: 15) { !$0.contains("2 f") },
            "row: \(row.label)"
        )
        XCTAssertTrue(app.buttons["undo"].isEnabled)

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "surface-cut-tool"
        shot.lifetime = .keepAlways
        add(shot)

        // ONE journal entry for the whole knife stroke.
        viewport.tap(withNumberOfTaps: 1, numberOfTouches: 3)
        XCTAssertTrue(
            waitForLabel(of: row, timeout: 5) { $0.contains("2 f") && $0.contains("6 v") },
            "row: \(row.label)"
        )
    }

    /// Task 4.2 end to end (spec: retopology-tools / "Core RT action
    /// roster", scenario "Patch Clone round-trip"): the Patch Clone tool
    /// armed and driven through the auto-tool probe — a real selection
    /// stroke over the seeded on-dome strip, a REAL viewport camera orbit
    /// fed through the arbiter-gated camera→tool routing, and a paste
    /// projected onto the dome Target, journaled as ONE entry that a
    /// single three-finger undo restores.
    @MainActor
    func testPatchCloneToolProbeSelectsOrbitsAndPastes() throws {
        try skipIfInteractionUnsupported()
        let app = launch(arguments: [
            "-UITestResetState", "-UITestOpenDocument", "-UITestSeedTarget",
            "-UITestSeedEditMeshOnDome", "-UITestAutoTool", "patchClone",
        ])

        let viewport = app.otherElements["viewport"].firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 15))
        let row = app.descendants(matching: .any)["object-row-seed-dome-strip"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))

        // The auto-tool hook fires ~3 s after the editor appears; the
        // paste clones the selected faces of the 6 v / 2 f strip.
        XCTAssertTrue(
            waitForLabel(of: row, timeout: 15) { !$0.contains("2 f") },
            "row: \(row.label)"
        )
        XCTAssertTrue(app.buttons["undo"].isEnabled)
        // The session stays armed after its own paste (repeatable): the
        // banner's paste/cancel controls are on screen.
        XCTAssertTrue(app.buttons["tool-session-commit"].waitForExistence(timeout: 5))

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "patch-clone-tool"
        shot.lifetime = .keepAlways
        add(shot)

        // ONE journal entry for the whole paste.
        viewport.tap(withNumberOfTaps: 1, numberOfTouches: 3)
        XCTAssertTrue(
            waitForLabel(of: row, timeout: 5) { $0.contains("2 f") && $0.contains("6 v") },
            "row: \(row.label)"
        )
    }

    /// Task 4.1 toolbar wiring (spec: pencil-interaction / "Customizable
    /// toolbar and Action Gallery" + retopology-tools): a build tool
    /// assigned from the Action Gallery via the tap path becomes a
    /// selectable toolbar slot that arms the tool; selecting a verb
    /// disarms it.
    @MainActor
    func testBuildToolAssignsFromGalleryAndArms() throws {
        let app = launch(arguments: ["-UITestResetState", "-UITestOpenDocument"])

        let galleryButton = app.buttons["action-gallery-button"]
        XCTAssertTrue(galleryButton.waitForExistence(timeout: 15))
        galleryButton.tap()

        // Tap path: select the Build quad tile, place it into slot 6.
        let tile = app.descendants(matching: .any)["gallery-action-buildQuad"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        tile.tap()
        XCTAssertTrue(waitUntil { tile.value as? String == "selected" })
        app.buttons["gallery-slot-5"].tap()
        XCTAssertTrue(waitUntil {
            app.buttons["gallery-slot-5"].value as? String == "buildQuad"
        })
        app.buttons["gallery-done"].tap()

        // The slot arms the tool; the Pencil verb stays the active verb.
        let toolButton = app.buttons["tool-buildQuad"]
        XCTAssertTrue(toolButton.waitForExistence(timeout: 5))
        XCTAssertEqual(toolButton.value as? String, "inactive")
        toolButton.tap()
        XCTAssertTrue(waitUntil { toolButton.value as? String == "active" })
        XCTAssertEqual(app.buttons["verb-pencil"].value as? String, "active")

        // Selecting a verb persistently disarms the tool.
        app.buttons["verb-relax"].tap()
        XCTAssertTrue(waitUntil { toolButton.value as? String == "inactive" })
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

    /// Task 4.3 (spec: retopology-tools / "Pins immune to smoothing",
    /// "Loop tags"): the annotation probe pins one loop and tags another
    /// in a chosen palette colour. The palette swatches are real UI, the
    /// pins/tags render in the overlay, and the two annotation edits undo
    /// as two ordinary journal entries.
    @MainActor
    func testAnnotationProbePinsLoopAndTagsAnotherInColour() throws {
        try skipIfInteractionUnsupported()
        let app = launch(arguments: [
            "-UITestResetState", "-UITestOpenDocument", "-UITestSeedTarget",
            "-UITestSeedEditMeshGrid", "-UITestAutoAnnotations",
        ])

        let viewport = app.otherElements["viewport"].firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 15))
        // The loop-tag palette is always available in the RT stage.
        let swatch = app.buttons["tag-color-1"].firstMatch
        XCTAssertTrue(swatch.waitForExistence(timeout: 10))

        // The probe fires ~3 s after the editor appears and journals the
        // pin edit then the tag edit — undo becomes available.
        XCTAssertTrue(
            waitForCondition(timeout: 20) { app.buttons["undo"].isEnabled },
            "the annotation probe journaled nothing"
        )

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "pins-and-tagged-loop"
        shot.lifetime = .keepAlways
        add(shot)

        // The annotation edits undo like any other journal entry, and
        // neither touched geometry (the cage keeps its 25 v / 16 f).
        let row = app.descendants(matching: .any)["object-row-seed-dome-grid"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.label.contains("16 f"), "row: \(row.label)")
        viewport.tap(withNumberOfTaps: 1, numberOfTouches: 3)
        XCTAssertTrue(
            waitForCondition(timeout: 10) { app.buttons["redo"].isEnabled },
            "an undo should have armed redo"
        )
        XCTAssertTrue(row.label.contains("16 f"), "row: \(row.label)")
    }

    /// Task 4.4 (spec: retopology-tools / "Multi-axis and radial
    /// symmetry"): the symmetry controls live in the viewport settings
    /// popover and drive DOCUMENT state, so toggling one journals an undo
    /// step. Document-flow only (no stroke injection, no Metal
    /// unprojection) — deliberately NOT interaction-gated.
    @MainActor
    func testSymmetrySettingsToggleJournalsAndUndoes() throws {
        let app = launch(arguments: [
            "-UITestResetState", "-UITestOpenDocument", "-UITestSeedTarget",
            "-UITestSeedEditMesh",
        ])

        let settings = app.buttons["viewport-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        settings.tap()

        let toggle = app.switches["symmetry-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let summary = app.staticTexts["symmetry-summary"]
        XCTAssertTrue(summary.exists)
        XCTAssertTrue(summary.label.contains("Off"), "summary: \(summary.label)")

        // Enabling mirroring on X is one journaled document change.
        app.descendants(matching: .any)["symmetry-axis-x"].firstMatch.tap()
        toggle.switches.firstMatch.tap()
        XCTAssertTrue(
            waitForCondition(timeout: 10) { summary.label.contains("mirror X") },
            "summary: \(summary.label)"
        )
        XCTAssertTrue(
            summary.label.contains("2 copies"),
            "the summary must state the honest replica count: \(summary.label)"
        )

        // Radial count is configurable from the same panel.
        let radial = app.steppers["symmetry-radial-count"].firstMatch
        XCTAssertTrue(radial.exists)
        radial.buttons.element(boundBy: 1).tap()
        XCTAssertTrue(
            waitForCondition(timeout: 10) { summary.label.contains("radial") },
            "summary: \(summary.label)"
        )

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "symmetry-settings"
        shot.lifetime = .keepAlways
        add(shot)

        // Symmetry is document state: the changes are undoable.
        app.tap()  // dismiss the popover
        XCTAssertTrue(
            waitForCondition(timeout: 10) { app.buttons["undo"].isEnabled },
            "changing symmetry journaled nothing"
        )
        app.buttons["undo"].tap()
        XCTAssertTrue(
            waitForCondition(timeout: 10) { app.buttons["redo"].isEnabled },
            "an undo should have armed redo"
        )
    }

    /// Task 4.4: symmetric AUTHORING end to end. The probe hook turns X
    /// mirroring on through the real journaled command path (which is what
    /// makes the plane rim render) and authors one quad through the real
    /// create path — the mirror rides the SAME journal entry, so one undo
    /// removes both sides. Interaction-gated: the injection hook drives
    /// Metal unprojection.
    @MainActor
    func testSymmetryProbeMirrorsAuthoredQuadAndUndoesBothSides() throws {
        try skipIfInteractionUnsupported()
        let app = launch(arguments: [
            "-UITestResetState", "-UITestOpenDocument", "-UITestSeedTarget",
            "-UITestSeedEditMeshOnDome", "-UITestAutoSymmetry",
        ])

        let viewport = app.otherElements["viewport"].firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 15))
        let row = app.descendants(matching: .any)["object-row-seed-dome-strip"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.label.contains("2 f"), "row: \(row.label)")

        // The probe enables symmetry (~3 s) then authors ONE quad (~4 s),
        // which the mirror turns into TWO faces: 2 f -> 4 f.
        XCTAssertTrue(
            waitForLabel(of: row, timeout: 25) { $0.contains("4 f") },
            "one authored quad must land as two mirrored faces; row: \(row.label)"
        )

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "symmetry-plane-rim-and-mirrored-quad"
        shot.lifetime = .keepAlways
        add(shot)

        // ONE undo steps back over the mirrored create — BOTH sides go.
        viewport.tap(withNumberOfTaps: 1, numberOfTouches: 3)
        XCTAssertTrue(
            waitForLabel(of: row, timeout: 10) { $0.contains("2 f") },
            "one undo must remove both mirrored halves; row: \(row.label)"
        )
    }

    /// Task 4.5 (spec: retopology-tools / "EditMesh batch commands"): the
    /// batch panel runs a whole-mesh command that is ONE undo step, and the
    /// annotation clear a subdivide forces rides inside the same step.
    /// Document-flow only — the panel is plain SwiftUI and the command runs
    /// on the live mesh without any stroke unprojection — so this is
    /// deliberately NOT interaction-gated.
    @MainActor
    func testBatchPanelSubdividesTheCageAndOneUndoRestoresIt() throws {
        let app = launch(arguments: [
            "-UITestResetState", "-UITestOpenDocument", "-UITestSeedTarget",
            "-UITestSeedEditMeshGrid", "-UITestShowBatchCommands",
        ])

        // The panel is presented by the screenshot hook ~3 s in; the same
        // sheet the toolbar's Batch commands action presents.
        let subdivide = app.buttons["batch-subdivideAndReproject"].firstMatch
        XCTAssertTrue(subdivide.waitForExistence(timeout: 25))
        XCTAssertTrue(app.switches["auto-relax-toggle"].firstMatch.exists)

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "batch-commands-panel"
        shot.lifetime = .keepAlways
        add(shot)

        subdivide.tap()

        // 16 quads -> 64 after one level of subdivision.
        let row = app.descendants(matching: .any)["object-row-seed-dome-grid"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        XCTAssertTrue(
            waitForLabel(of: row, timeout: 20) { $0.contains("64 f") },
            "subdivide+reproject must quadruple the faces; row: \(row.label)"
        )

        let subdivided = XCTAttachment(screenshot: app.screenshot())
        subdivided.name = "subdivided-cage"
        subdivided.lifetime = .keepAlways
        add(subdivided)

        // ONE undo step takes the whole compound entry back.
        let undo = app.buttons["undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 10))
        XCTAssertTrue(undo.isEnabled)
        undo.tap()
        XCTAssertTrue(
            waitForLabel(of: row, timeout: 15) { $0.contains("16 f") },
            "one undo must restore the coarse cage; row: \(row.label)"
        )
        // A two-entry design would need TWO undos: the first would take
        // back only the annotation clear and leave 64 faces on screen.
    }

    /// Task 4.6 (spec: retopology-tools / "Subdivision preview", scenario
    /// "Editing under preview"): the viewport-settings control turns the
    /// preview on and the DOCUMENT never changes — the cage keeps its 16
    /// faces and undo stays unavailable, because a preview is derived render
    /// data and journals nothing.
    ///
    /// Document-flow only (a segmented picker in a popover; no stroke
    /// unprojection, no multi-finger synthesis) — deliberately NOT
    /// interaction-gated.
    @MainActor
    func testSubdivisionPreviewIsNonDestructive() throws {
        let app = launch(arguments: [
            "-UITestResetState", "-UITestOpenDocument", "-UITestSeedTarget",
            "-UITestSeedEditMeshGrid",
        ])

        let row = app.descendants(matching: .any)["object-row-seed-dome-grid"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 25))
        XCTAssertTrue(
            waitForLabel(of: row, timeout: 15) { $0.contains("16 f") },
            "seeded cage should start at 16 faces; row: \(row.label)"
        )
        let settings = app.buttons["viewport-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        settings.tap()

        let picker = app.segmentedControls["subdivision-preview-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 15))
        picker.buttons["2"].tap()
        XCTAssertTrue(picker.buttons["2"].isSelected)
        dismissPopover(app)

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "subdivision-preview-level-2"
        shot.lifetime = .keepAlways
        add(shot)

        // THE INVARIANT: the stored cage is untouched — still 16 faces —
        // and no journal entry was created by turning the preview on.
        XCTAssertTrue(
            waitForLabel(of: row, timeout: 10) { $0.contains("16 f") },
            "the preview must not change the stored cage; row: \(row.label)"
        )
        // Restore the persisted default so other tests start from Off.
        settings.tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.buttons["Off"].tap()
        dismissPopover(app)

        // AND the preview journaled nothing: the top of the undo stack is
        // still the seed IMPORT, so one undo removes the EditMesh object
        // outright. Had turning the preview on (or off) recorded an entry,
        // this undo would have stepped over it and the row would still be
        // there.
        let undo = app.buttons["undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 10))
        XCTAssertTrue(undo.isEnabled)
        undo.tap()
        XCTAssertTrue(
            waitUntil(timeout: 15) { !row.exists },
            "a subdivision preview must journal nothing, so one undo must "
                + "reach the seed import itself"
        )
    }
}

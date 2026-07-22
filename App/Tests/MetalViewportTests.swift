import CyberKit
import MetalKit
import SwiftUI
import Testing
import UIKit
@testable import CyberTopology

// Gesture-recognizer stubs: deterministic values without synthesized touches.
private final class PanStub: UIPanGestureRecognizer {
    var stubTranslation: CGPoint
    var stubState: UIGestureRecognizer.State = .changed

    init(translation: CGPoint, state: UIGestureRecognizer.State = .changed) {
        stubTranslation = translation
        stubState = state
        super.init(target: nil, action: nil)
    }

    override var state: UIGestureRecognizer.State {
        get { stubState }
        set { stubState = newValue }
    }

    override func translation(in view: UIView?) -> CGPoint { stubTranslation }
    override func setTranslation(_ translation: CGPoint, in view: UIView?) {
        stubTranslation = translation
    }
}

@MainActor
struct MetalViewportTests {
    private func makeViewport(
        bundle: DocumentBundle = DocumentBundle()
    ) -> MetalViewport {
        MetalViewport(
            bundle: bundle, orbitSpeed: 1, zoomSpeed: 1, onUndo: {}, onRedo: {}
        )
    }

    private func seededBundle(roles: [DocumentManifest.Object.Role]) throws -> DocumentBundle {
        var bundle = DocumentBundle()
        let mesh = try Mesh.loadOBJ(at: UITestSupport.writeSeedOBJ())
        for (index, role) in roles.enumerated() {
            try bundle.addObject(name: "obj-\(index)", role: role, mesh: mesh)
        }
        return bundle
    }

    // MARK: - Render-object selection

    @Test func renderableObjectPrefersTargetOverEditMesh() throws {
        let bundle = try seededBundle(roles: [.editMesh, .target])
        let object = try #require(MetalViewport.renderableObject(in: bundle.manifest))
        #expect(object.role == .target)
    }

    @Test func renderableObjectFallsBackToEditMesh() throws {
        let bundle = try seededBundle(roles: [.editMesh])
        let object = try #require(MetalViewport.renderableObject(in: bundle.manifest))
        #expect(object.role == .editMesh)
    }

    @Test func renderableObjectIsNilForEmptyDocument() {
        #expect(MetalViewport.renderableObject(in: DocumentManifest()) == nil)
    }

    // MARK: - View construction and gesture arbitration

    @Test func makeViewInstallsArbitratedGestureSet() throws {
        let coordinator = makeViewport().makeCoordinator()
        let view = coordinator.makeView()
        #expect(view.accessibilityIdentifier == "viewport")
        #expect(view is MTKView)

        let orbit = try #require(coordinator.orbitRecognizer)
        #expect(orbit.maximumNumberOfTouches == 1)

        let twoFingerPan = try #require(coordinator.twoFingerPanRecognizer)
        #expect(twoFingerPan.minimumNumberOfTouches == 2)
        #expect(twoFingerPan.maximumNumberOfTouches == 2)

        let doubleTap = try #require(coordinator.doubleTapRecognizer)
        #expect(doubleTap.numberOfTapsRequired == 2)
        #expect(doubleTap.numberOfTouchesRequired == 1)

        let pinch = try #require(coordinator.pinchRecognizer)
        // 4 camera recognizers + the arbiter's touch observer (task 3.1)
        // + the hover-preview recognizer (task 3.6) + the INTERNAL
        // recognizer UIKit installs alongside the `UIPencilInteraction`
        // for squeeze delivery (task 3.7 — not ours, not touch-driven).
        let installed = view.gestureRecognizers ?? []
        #expect(installed.count == 7)
        let observer = try #require(coordinator.observerRecognizer)
        #expect(installed.contains { $0 === observer })
        let hover = try #require(coordinator.hoverRecognizer)
        #expect(installed.contains { $0 === hover })
        let pencil = try #require(coordinator.pencilInteraction)
        #expect(view.interactions.contains { $0 === pencil })
        // Exactly one installed recognizer is not ours: the pencil
        // interaction's internal one.
        let ours: [UIGestureRecognizer] = [
            orbit, pinch, twoFingerPan, doubleTap, observer, hover,
        ]
        let foreign = installed.filter { candidate in
            !ours.contains { $0 === candidate }
        }
        #expect(foreign.count == 1)
        // Every TOUCH recognizer of ours is delegated so the arbiter can
        // gate its touches; the hover recognizer consumes hover events —
        // not touches — and the pencil interaction's internal recognizer
        // consumes squeezes, so both stay outside the arbiter's touch gate.
        #expect(installed.allSatisfy { recognizer in
            recognizer === hover
                || foreign.contains { $0 === recognizer }
                || recognizer.delegate === coordinator
        })
        #expect(coordinator.undoTapRecognizers.allSatisfy { $0.delegate === coordinator })

        // The undo/redo tap overlay is embedded as the topmost subview with
        // its three- and four-finger recognizers intact.
        let overlay = try #require(view.subviews.first)
        let taps = overlay.gestureRecognizers?.compactMap { $0 as? UITapGestureRecognizer } ?? []
        #expect(taps.map(\.numberOfTouchesRequired).sorted() == [3, 4])
    }

    @Test func onlyPinchAndTwoFingerPanRecognizeSimultaneously() throws {
        let coordinator = makeViewport().makeCoordinator()
        _ = coordinator.makeView()
        let pinch = try #require(coordinator.pinchRecognizer)
        let twoFingerPan = try #require(coordinator.twoFingerPanRecognizer)
        let orbit = try #require(coordinator.orbitRecognizer)
        let doubleTap = try #require(coordinator.doubleTapRecognizer)

        #expect(coordinator.gestureRecognizer(pinch, shouldRecognizeSimultaneouslyWith: twoFingerPan))
        #expect(coordinator.gestureRecognizer(twoFingerPan, shouldRecognizeSimultaneouslyWith: pinch))
        #expect(!coordinator.gestureRecognizer(pinch, shouldRecognizeSimultaneouslyWith: orbit))
        #expect(!coordinator.gestureRecognizer(orbit, shouldRecognizeSimultaneouslyWith: doubleTap))
        #expect(!coordinator.gestureRecognizer(orbit, shouldRecognizeSimultaneouslyWith: twoFingerPan))

        // The touch observer pairs with everything (it must never be
        // force-failed, or the arbiter would miss touch end events).
        let observer = try #require(coordinator.observerRecognizer)
        #expect(coordinator.gestureRecognizer(observer, shouldRecognizeSimultaneouslyWith: orbit))
        #expect(coordinator.gestureRecognizer(pinch, shouldRecognizeSimultaneouslyWith: observer))
    }

    @Test func makeViewFallsBackWithoutMetal() throws {
        let coordinator = makeViewport().makeCoordinator()
        let view = coordinator.makeView(renderer: nil)
        #expect(!(view is MTKView))
        #expect(view.accessibilityIdentifier == "viewport")
        #expect(coordinator.renderer == nil)
        // Mesh sync degrades gracefully with no renderer.
        coordinator.syncMesh(from: DocumentBundle())
    }

    /// Regression: the Metal-unavailable fallback must still mount the
    /// undo/redo tap overlay — gesture undo/redo (spec: document-model /
    /// "Gesture undo/redo") works even without a renderer.
    @Test func fallbackViewKeepsUndoGestureOverlay() throws {
        var undone = 0
        var redone = 0
        let viewport = MetalViewport(
            bundle: DocumentBundle(), orbitSpeed: 1, zoomSpeed: 1,
            onUndo: { undone += 1 }, onRedo: { redone += 1 }
        )
        let coordinator = viewport.makeCoordinator()
        let view = coordinator.makeView(renderer: nil)

        let overlay = try #require(view.subviews.first)
        let taps = overlay.gestureRecognizers?.compactMap { $0 as? UITapGestureRecognizer } ?? []
        #expect(taps.map(\.numberOfTouchesRequired).sorted() == [3, 4])
        #expect(overlay.autoresizingMask == [.flexibleWidth, .flexibleHeight])

        // The overlay is wired to the same undo coordinator the document
        // handlers flow through.
        coordinator.undoCoordinator.undoTap()
        coordinator.undoCoordinator.redoTap()
        #expect(undone == 1)
        #expect(redone == 1)
    }

    // MARK: - Gesture handlers drive the camera

    @Test func handlersRouteGesturesToRenderer() throws {
        let coordinator = makeViewport().makeCoordinator()
        _ = coordinator.makeView()
        let renderer = try #require(coordinator.renderer)
        renderer.load(mesh: try Mesh.loadOBJ(at: UITestSupport.writeSeedOBJ()))
        let start = renderer.camera

        coordinator.handleOrbit(PanStub(translation: CGPoint(x: 25, y: -10)))
        #expect(renderer.camera.azimuth != start.azimuth)
        #expect(renderer.camera.elevation != start.elevation)

        let pinch = UIPinchGestureRecognizer()
        pinch.scale = 2
        coordinator.handlePinch(pinch)
        #expect(renderer.camera.distance < start.distance)
        #expect(pinch.scale == 1)  // incremental scale reset

        let focusBefore = renderer.camera.focus
        coordinator.handleTwoFingerPan(PanStub(translation: CGPoint(x: 40, y: 12)))
        #expect(renderer.camera.focus != focusBefore)

        // Double-tap reframes (animated); driving the animation to its end
        // restores frame-to-fit.
        coordinator.handleDoubleTap(UITapGestureRecognizer())
        _ = renderer.stepAnimation(at: .greatestFiniteMagnitude)
        #expect(renderer.camera.focus == renderer.bounds.center)
    }

    // MARK: - Mesh sync

    @Test func syncMeshLoadsAndUnloadsWithDocumentChanges() throws {
        let coordinator = makeViewport().makeCoordinator()
        _ = coordinator.makeView()
        let renderer = try #require(coordinator.renderer)

        coordinator.syncMesh(from: DocumentBundle())
        #expect(!renderer.hasMesh)

        let bundle = try seededBundle(roles: [.editMesh])
        coordinator.syncMesh(from: bundle)
        #expect(renderer.hasMesh)

        // Unchanged object list: no reload (a moved camera stays put).
        renderer.orbit(byPoints: SIMD2(50, 0))
        let moved = renderer.camera
        coordinator.syncMesh(from: bundle)
        #expect(renderer.camera == moved)

        // Object list changed (e.g. undo of the import): mesh unloads.
        coordinator.syncMesh(from: DocumentBundle())
        #expect(!renderer.hasMesh)
    }

    @Test func syncMeshPrefersTargetWhenBothRolesExist() throws {
        let coordinator = makeViewport().makeCoordinator()
        _ = coordinator.makeView()
        let renderer = try #require(coordinator.renderer)
        let bundle = try seededBundle(roles: [.editMesh, .target])
        coordinator.syncMesh(from: bundle)
        #expect(renderer.hasMesh)
    }

    // MARK: - Undo overlay plumbing

    @Test func undoCoordinatorRoutesTapsToDocumentHandlers() {
        var undone = 0
        var redone = 0
        let viewport = MetalViewport(
            bundle: DocumentBundle(), orbitSpeed: 1, zoomSpeed: 1,
            onUndo: { undone += 1 }, onRedo: { redone += 1 }
        )
        let coordinator = viewport.makeCoordinator()
        coordinator.undoCoordinator.undoTap()
        coordinator.undoCoordinator.redoTap()
        #expect(undone == 1)
        #expect(redone == 1)
    }

    // MARK: - Recognizer context wiring (task 3.2)

    @Test func syncMeshInstallsRecognizerEditMeshContext() throws {
        let coordinator = makeViewport().makeCoordinator()
        _ = coordinator.makeView()
        try #require(coordinator.renderer != nil, "Metal device unavailable")

        coordinator.syncMesh(from: DocumentBundle())
        #expect(coordinator.recognizerEditMesh == nil)

        let bundle = try seededBundle(roles: [.editMesh])
        coordinator.syncMesh(from: bundle)
        #expect(coordinator.recognizerEditMesh != nil)

        // A stroke captured now interprets with the coordinator-installed
        // context (live camera matrix + EditMesh). Deterministic element
        // resolution with a pinned matrix is covered by
        // StrokeRecognitionWiringTests; here the wiring must produce a
        // record end to end.
        let capture = coordinator.inputModel.controller.capture
        capture.begin(
            source: .pencil, verb: .pencil, sample: .init(time: 0, x: 0.2, y: 0.2)
        )
        capture.append(sample: .init(time: 0.1, x: 0.8, y: 0.8))
        capture.end()
        #expect(coordinator.inputModel.lastInterpretation != nil)

        // Removing the EditMesh clears the recognizer context again.
        coordinator.syncMesh(from: DocumentBundle())
        #expect(coordinator.recognizerEditMesh == nil)
    }

    // MARK: - Settings view

    @Test func settingsViewRendersSliders() {
        let view = ViewportSettingsView(
            orbitSpeed: .constant(1.5), zoomSpeed: .constant(0.5),
            overlayOpacity: .constant(0.7), fillOpacity: .constant(0.3),
            xrayEnabled: .constant(true),
            occlusionBias: .constant(0.004), ghostDebugEnabled: .constant(true),
            resolutionScale: .constant(0.75), leftHandedToolbar: .constant(true),
            snapHapticsEnabled: .constant(true), strokeDebugHUD: .constant(true),
            subdivisionPreviewLevel: .constant(2), hasTarget: true
        )
        let host = UIHostingController(rootView: view)
        host.view.frame = CGRect(x: 0, y: 0, width: 400, height: 500)
        host.view.layoutIfNeeded()
        #expect(host.sizeThatFits(in: CGSize(width: 400, height: 500)).height > 0)
    }

    @Test func settingsDefaultsAreSane() {
        #expect(ViewportSettings.defaultSpeed == 1.0)
        #expect(ViewportSettings.speedRange.contains(ViewportSettings.defaultSpeed))
        #expect(
            ViewportSettings.overlayOpacityRange
                .contains(ViewportSettings.defaultOverlayOpacity)
        )
        #expect(
            ViewportSettings.occlusionBiasRange
                .contains(ViewportSettings.defaultOcclusionBias)
        )
    }

    // MARK: - EditMesh overlay sync (task 2.3)

    @Test func syncMeshLoadsEditMeshIntoOverlay() throws {
        let coordinator = makeViewport().makeCoordinator()
        _ = coordinator.makeView()
        let renderer = try #require(coordinator.renderer)

        let bundle = try seededBundle(roles: [.editMesh, .target])
        coordinator.syncMesh(from: bundle)
        #expect(renderer.hasMesh)
        #expect(renderer.hasOverlay)
        // The seed quad's 4 authored edges — no fan diagonal.
        #expect(renderer.overlayPath.edgeIndexCount == 8)

        // Removing every object clears the overlay too.
        coordinator.syncMesh(from: DocumentBundle())
        #expect(!renderer.hasOverlay)
    }

    @Test func targetOnlyDocumentHasNoOverlay() throws {
        let coordinator = makeViewport().makeCoordinator()
        _ = coordinator.makeView()
        let renderer = try #require(coordinator.renderer)
        coordinator.syncMesh(from: try seededBundle(roles: [.target]))
        #expect(renderer.hasMesh)
        #expect(!renderer.hasOverlay)
    }

    /// The creation micro-animation replays for a NEW EditMesh object but
    /// not when the same object's manifest entry merely changes.
    @Test func overlayAnimationRestartsOnlyForNewEditMesh() throws {
        let coordinator = makeViewport().makeCoordinator()
        _ = coordinator.makeView()
        let renderer = try #require(coordinator.renderer)

        var bundle = try seededBundle(roles: [.editMesh])
        coordinator.syncMesh(from: bundle)
        let firstClock = try #require(renderer.overlayCreationTime)

        // Same EditMesh object, manifest touched by an unrelated change.
        let mesh = try Mesh.loadOBJ(at: UITestSupport.writeSeedOBJ())
        try bundle.addObject(name: "target", role: .target, mesh: mesh)
        coordinator.syncMesh(from: bundle)
        #expect(renderer.overlayCreationTime == firstClock)

        // A different EditMesh object restarts the animation clock.
        let replaced = try seededBundle(roles: [.editMesh])
        coordinator.syncMesh(from: replaced)
        let secondClock = try #require(renderer.overlayCreationTime)
        #expect(secondClock >= firstClock)
        #expect(replaced.manifest.objects.first?.id != bundle.manifest.objects.first?.id)
    }

    // MARK: - Ghost debug preview sync (task 2.4)

    /// The DEBUG ghost preview mirrors the EditMesh into the ghost pipeline
    /// while enabled, reuses the loaded ghost across unrelated syncs, and
    /// clears when disabled or when the EditMesh disappears.
    @Test func ghostPreviewSyncFollowsToggleAndEditMesh() throws {
        let coordinator = makeViewport().makeCoordinator()
        _ = coordinator.makeView()
        let renderer = try #require(coordinator.renderer)
        let bundle = try seededBundle(roles: [.editMesh])
        coordinator.syncMesh(from: bundle)

        // Off: nothing loads.
        coordinator.syncGhostPreview(from: bundle, enabled: false)
        #expect(!renderer.hasGhost)

        // On: the EditMesh loads as ghost with the debug normal-offset.
        coordinator.syncGhostPreview(from: bundle, enabled: true)
        #expect(renderer.hasGhost)
        #expect(renderer.ghostStyle.normalOffset > 0)
        // The seed quad triangulates to 2 triangles = 6 ghost indices.
        #expect(renderer.ghostPath.indexCount == 6)

        // Same EditMesh object: no reload churn (sharing path unchanged).
        let sharing = renderer.ghostPath.activeSharing
        coordinator.syncGhostPreview(from: bundle, enabled: true)
        #expect(renderer.ghostPath.activeSharing == sharing)

        // Off again: ghost clears.
        coordinator.syncGhostPreview(from: bundle, enabled: false)
        #expect(!renderer.hasGhost)

        // Enabled but no EditMesh in the document: stays clear.
        coordinator.syncGhostPreview(from: DocumentBundle(), enabled: true)
        #expect(!renderer.hasGhost)
    }

    /// Regression: the preview must key reloads on the PAYLOAD too, not
    /// just the EditMesh object identity — verb edits and undo/redo change
    /// the payload under the same object id, and a stale ghost would
    /// visibly diverge from the wireframe overlay.
    @Test func ghostPreviewReloadsWhenTheEditMeshPayloadChanges() throws {
        let coordinator = makeViewport().makeCoordinator()
        _ = coordinator.makeView()
        let renderer = try #require(coordinator.renderer)
        var bundle = try seededBundle(roles: [.editMesh])
        coordinator.syncGhostPreview(from: bundle, enabled: true)
        #expect(renderer.ghostPath.indexCount == 6)  // seed quad

        // Same object id, new payload (a mesh edit / undo-redo): the ghost
        // reloads to the edited geometry.
        let object = try #require(bundle.manifest.objects.first)
        let edited = try Mesh.loadOBJ(at: UITestSupport.writeSeedTargetOBJ())
        bundle.payloads[object.payloadFile] = try edited.payloadData()
        coordinator.syncGhostPreview(from: bundle, enabled: true)
        // 10x10 quad grid = 200 triangles = 600 indices.
        #expect(renderer.ghostPath.indexCount == 600)
    }

    /// `updateUIView` pushes these values through `overlaySettings`; the
    /// mapping itself is what can regress, so it is asserted directly
    /// (`UIViewRepresentableContext` cannot be constructed in tests).
    @Test func viewportMapsDisplayOptionsToOverlaySettings() {
        let viewport = MetalViewport(
            bundle: DocumentBundle(), orbitSpeed: 1, zoomSpeed: 1,
            overlayOpacity: 0.4, xrayEnabled: true, occlusionBias: 0.01,
            onUndo: {}, onRedo: {}
        )
        let settings = viewport.overlaySettings
        #expect(settings.opacity == 0.4)
        #expect(settings.xrayEnabled)
        #expect(settings.occlusionBias == Float(0.01))
    }

    // MARK: - Frame pacing wiring (task 2.5)

    /// Render-on-demand configuration: the MTKView never free-runs; the
    /// pacer drives it via setNeedsDisplay.
    @Test func makeViewConfiguresRenderOnDemand() throws {
        let coordinator = makeViewport().makeCoordinator()
        let view = try #require(coordinator.makeView() as? MTKView)
        #expect(view.isPaused)
        #expect(view.enableSetNeedsDisplay)
        // Initial frame scheduled, then idle (no display link running).
        #expect(coordinator.framePacer.scheduledDrawCount >= 1)
        #expect(coordinator.framePacer.isDisplayLinkPaused)
    }

    /// Camera gesture lifetimes pin continuous drawing; idle parks the
    /// display link again (battery contract).
    @Test func gestureLifecycleDrivesFramePacer() throws {
        let coordinator = makeViewport().makeCoordinator()
        _ = coordinator.makeView()
        let pacer = coordinator.framePacer
        #expect(pacer.isDisplayLinkPaused)

        coordinator.handleOrbit(PanStub(translation: CGPoint(x: 5, y: 5), state: .began))
        #expect(!pacer.isDisplayLinkPaused)
        coordinator.handleOrbit(PanStub(translation: CGPoint(x: 5, y: 5), state: .changed))
        #expect(!pacer.isDisplayLinkPaused)
        coordinator.handleOrbit(PanStub(translation: .zero, state: .ended))
        #expect(pacer.isDisplayLinkPaused)
    }

    /// Renderer state changes flow through onNeedsDisplay into the pacer
    /// (a mesh load schedules a draw without any gesture).
    @Test func rendererInvalidationsScheduleDraws() throws {
        let coordinator = makeViewport().makeCoordinator()
        _ = coordinator.makeView()
        let before = coordinator.framePacer.scheduledDrawCount
        coordinator.syncMesh(from: try seededBundle(roles: [.target]))
        #expect(coordinator.framePacer.scheduledDrawCount > before)
    }

    /// The animated double-tap reframe keeps the display link running until
    /// the camera animation completes.
    @Test func animatedReframeRunsDisplayLinkWhileAnimating() throws {
        let coordinator = makeViewport().makeCoordinator()
        _ = coordinator.makeView()
        let renderer = try #require(coordinator.renderer)
        renderer.load(mesh: try Mesh.loadOBJ(at: UITestSupport.writeSeedOBJ()))
        renderer.orbit(byPoints: SIMD2(100, 40))

        coordinator.handleDoubleTap(UITapGestureRecognizer())
        #expect(!coordinator.framePacer.isDisplayLinkPaused)

        // Drive the animation to completion; the next pacing decision idles.
        _ = renderer.stepAnimation(at: .greatestFiniteMagnitude)
        coordinator.framePacer.invalidate()
        #expect(coordinator.framePacer.isDisplayLinkPaused)
    }

    // MARK: - Resolution scale wiring (task 2.5)

    /// applyResolutionScale pushes the scale into the renderer, picks the
    /// upscaler for this device, and syncs view content scale with the
    /// renderer's points→pixels factor.
    @Test func applyResolutionScaleSyncsViewAndRenderer() throws {
        let coordinator = makeViewport().makeCoordinator()
        let view = try #require(coordinator.makeView() as? ViewportMetalView)
        let renderer = try #require(coordinator.renderer)

        coordinator.applyResolutionScale(0.5)
        #expect(renderer.resolutionScale == 0.5)
        let desired = try #require(view.desiredContentScale)
        let screenScale = view.traitCollection.displayScale > 0
            ? view.traitCollection.displayScale : 1
        #expect(
            desired == ResolutionScalePolicy.contentScaleFactor(
                screenScale: screenScale,
                resolutionScale: 0.5,
                upscaler: renderer.activeUpscalerKind
            )
        )
        #expect(renderer.contentScale == Float(desired))

        // Reapplying the same scale is a no-op; a new scale re-syncs.
        coordinator.applyResolutionScale(0.5)
        coordinator.applyResolutionScale(1.0)
        #expect(renderer.resolutionScale == 1.0)
        // At 100% no upscaler is selected and the drawable is native-scale.
        #expect(renderer.activeUpscalerKind == .none)
        #expect(view.desiredContentScale == screenScale)
    }

    /// The scaled drawable never blurs UI chrome: only the MTKView's own
    /// content scale changes; sibling views are untouched.
    @Test func resolutionScaleTouchesOnlyTheMetalView() throws {
        let coordinator = makeViewport().makeCoordinator()
        let view = try #require(coordinator.makeView() as? ViewportMetalView)
        let overlay = try #require(view.subviews.first)  // undo tap overlay
        let overlayScaleBefore = overlay.contentScaleFactor

        coordinator.applyResolutionScale(0.5)
        #expect(view.desiredContentScale != nil)
        #expect(overlay.contentScaleFactor == overlayScaleBefore)
    }
}

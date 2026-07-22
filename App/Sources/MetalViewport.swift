import CyberKit
import MetalKit
import SwiftUI
import UIKit

/// MTKView-based viewport host (spec: viewport-rendering / "Robust camera
/// system"). Renders the document's first Target (EditMesh when no Target
/// exists) through `ViewportRenderer` and owns the camera gestures:
///
///   - one-finger drag   → turntable orbit
///   - pinch             → zoom (simultaneous with two-finger pan)
///   - two-finger drag   → pan
///   - one-finger 2-tap  → reframe-to-fit (camera rescue)
///
/// Gesture arbitration with undo/redo: the `UndoGestureView`-configured tap
/// overlay (three-finger tap undo, four-finger tap redo) sits INSIDE this
/// view's UIKit hierarchy as the topmost subview. Camera recognizers attach
/// to the MTKView itself — an ancestor of the overlay — so every touch is
/// seen by both: taps land on the overlay recognizers, drags/pinches move
/// past the tap slop and are claimed by the camera recognizers. Keeping the
/// overlay a SwiftUI `.overlay` sibling instead would hit-test-shield the
/// MTKView and dead-zone all camera input.
struct MetalViewport: UIViewRepresentable {
    let bundle: DocumentBundle
    /// Live accessor for the CURRENT document bundle (journal integrity,
    /// task 3.3): `bundle` is the SwiftUI snapshot of the last update pass,
    /// but touches can drain before the next pass runs (a queued pen-down
    /// right after a commit or an undo tap). The coordinator re-syncs from
    /// this accessor at stroke start so `MeshEditTransaction` always pins
    /// the document's true current payload — never a stale snapshot.
    var currentBundle: (@MainActor () -> DocumentBundle)? = nil
    var orbitSpeed: Double
    var zoomSpeed: Double
    /// Shared input arbitration model (task 3.1, design D5): the editor owns
    /// it so the verb toolbar and the viewport touches feed one arbiter.
    var inputModel = ViewportInputModel()
    /// EditMesh overlay display options (task 2.3).
    var overlayOpacity: Double = ViewportSettings.defaultOverlayOpacity
    var xrayEnabled: Bool = false
    var occlusionBias: Double = ViewportSettings.defaultOcclusionBias
    /// DEBUG-only ghost preview (task 2.4 demo path): renders the committed
    /// EditMesh as ghost geometry until the Weave solver (phase 5) exists.
    var ghostDebugEnabled: Bool = false
    /// Viewport resolution scale (task 2.5, spec: "Performance controls").
    var resolutionScale: Double = ViewportSettings.defaultResolutionScale
    /// Subdivision preview level (task 4.6, spec: "Subdivision preview"):
    /// 0 / 1 / 2. A DISPLAY setting — editing always continues on the base
    /// cage and the document never sees the preview.
    var subdivisionPreviewLevel: Int = ViewportSettings.defaultSubdivisionPreviewLevel
    /// Snap haptics on/off (task 3.7, spec: "haptics SHALL be
    /// user-disableable"). Disabling silences ticks only — the snap
    /// pre-highlight and the merge behavior itself are unaffected.
    var snapHapticsEnabled: Bool = true
    let onUndo: @MainActor () -> Void
    let onRedo: @MainActor () -> Void
    /// Journal sink for the verb layer (task 3.3): every mesh mutation
    /// arrives here as one `DocumentCommand` for `TopoDocument.perform`.
    var onCommit: @MainActor (DocumentCommand) -> Void = { _ in }
    /// Interpretation-chip swap sink (task 3.5): `(replacement, expected
    /// current)` for `TopoDocument.performReplacingLast` — the atomic
    /// revert-apply-replace that leaves exactly one journal entry. Returns
    /// whether the swap happened.
    var onReplaceCommit: @MainActor (DocumentCommand, DocumentCommand) -> Bool = { _, _ in
        false
    }

    /// The overlay display options as renderer settings (pushed on every
    /// `updateUIView`).
    var overlaySettings: OverlaySettings {
        OverlaySettings(
            opacity: Float(overlayOpacity),
            xrayEnabled: xrayEnabled,
            occlusionBias: Float(occlusionBias)
        )
    }

    /// Which object the viewport renders: the first Target, or the first
    /// EditMesh when the document has no Target yet.
    static func renderableObject(in manifest: DocumentManifest) -> DocumentManifest.Object? {
        manifest.objects.first { $0.role == .target } ?? manifest.objects.first
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onUndo: onUndo, onRedo: onRedo, inputModel: inputModel)
    }

    func makeUIView(context: Context) -> UIView {
        context.coordinator.makeView()
    }

    func updateUIView(_ view: UIView, context: Context) {
        let coordinator = context.coordinator
        coordinator.undoCoordinator.onUndo = onUndo
        coordinator.undoCoordinator.onRedo = onRedo
        coordinator.onCommit = onCommit
        coordinator.onReplaceCommit = onReplaceCommit
        coordinator.bundleProvider = currentBundle
        coordinator.meshEditor.snapHapticsEnabled = snapHapticsEnabled
        coordinator.renderer?.orbitSpeed = Float(orbitSpeed)
        coordinator.renderer?.zoomSpeed = Float(zoomSpeed)
        coordinator.renderer?.overlaySettings = overlaySettings
        coordinator.applyResolutionScale(resolutionScale)
        // Preview LEVEL first, document second: a level change and a
        // document change arriving in the same update pass must derive the
        // preview once, at the new level, from the new cage.
        coordinator.setSubdivisionPreviewLevel(
            SubdivisionPreviewLevel(clamping: subdivisionPreviewLevel)
        )
        coordinator.syncMesh(from: bundle)
        coordinator.syncGhostPreview(from: bundle, enabled: ghostDebugEnabled)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.framePacer.detach()
    }

    @MainActor
    final class Coordinator: NSObject {
        private(set) var renderer: ViewportRenderer?
        let undoCoordinator: UndoGestureView.Coordinator
        /// Render-on-demand pacer (task 2.5): the MTKView is paused; every
        /// draw is scheduled here (one-shot dirty flags + a display link
        /// for continuous phases, up to 120 Hz on ProMotion).
        let framePacer = ViewportFramePacer()
        /// The live MTKView (nil on the Metal-unavailable fallback).
        private(set) weak var metalView: ViewportMetalView?
        /// Last applied resolution scale; guards redundant reapplication
        /// on every SwiftUI update pass.
        private var appliedResolutionScale: Double?
        /// Identity + payload of the object in the solid render path;
        /// reloads happen only when either changes (imports, undo/redo,
        /// mesh edits of a target-less document's EditMesh).
        private var renderedObjectID: UUID?
        private var renderedPayload: Data?
        /// Identity of the EditMesh currently in the overlay pipeline; the
        /// creation micro-animation replays only when this changes (a newly
        /// imported/created EditMesh), not on every manifest touch.
        private var overlayObjectID: UUID?
        /// The overlay EditMesh's document payload bytes: mesh edits change
        /// them (the reload signal), and a cancelled verb stroke restores
        /// the live mesh from them (task 3.3).
        private var overlayPayload: Data?
        /// Manifest entry of the overlay EditMesh (verb transactions).
        /// Invariant: `editObject`/`overlayObjectID`/`overlayPayload`/
        /// `recognizerEditMesh` always describe ONE consistent snapshot —
        /// all four are set together or cleared together (`syncOverlay`).
        private(set) var editObject: DocumentManifest.Object?
        /// Annotations (loop tags + hidden faces, task 3.4) last pushed
        /// into the live mesh's render filters; annotation edits change the
        /// manifest without touching payload bytes, so they need their own
        /// change signal.
        private var overlayAnnotations: MeshAnnotations?
        /// Whether the document manifest currently contains an EditMesh
        /// object AT ALL — independent of whether its payload deserialized
        /// (`editObject` is nil in that failure case). The pencil verb's
        /// create-first-quad fallback keys on this so a broken snapshot can
        /// never journal a duplicate `.editMesh` object.
        private(set) var documentHasEditMesh = false
        /// Document symmetry state (task 4.4) last pushed to the renderer
        /// and handed to authoring contexts. Optional so "never set"
        /// (pre-4.4 documents) survives round-trips through the journal.
        private(set) var documentSymmetry: SymmetrySettings?
        /// Identity + payload of the EditMesh currently rendered as the
        /// DEBUG ghost preview; nil while the preview is off (task 2.4 demo
        /// path). Payload changes (mesh edits, undo/redo) reload the ghost
        /// so it never diverges from the wireframe overlay.
        private var ghostPreviewObjectID: UUID?
        private var ghostPreviewPayload: Data?
        /// EditMesh handle the stroke recognizer resolves context against
        /// (task 3.2) and the verbs mutate (task 3.3): the same
        /// deserialized mesh the overlay pipeline uploaded, retained so
        /// stage 2 and the edits run on live engine element ids.
        private(set) var recognizerEditMesh: Mesh?
        /// Target snapper + the mesh it snapshots (task 3.3): continuous
        /// snap projection for every verb. Rebuilt when the Target object
        /// changes (Targets are immutable, so identity suffices).
        private var targetObjectID: UUID?
        private var targetMesh: Mesh?
        private(set) var targetSnapper: SurfaceSnapper?
        /// Verb layer (task 3.3): applies the five verbs to the live mesh
        /// and journals every mutation through `onCommit`.
        let meshEditor = MeshEditController()
        /// Hover previews (task 3.6): ghost quad on empty surface, slide-
        /// loop highlight on interior edges, snap-target vertex highlight —
        /// fed by the UIKit hover recognizer below (Pencil hover on
        /// hover-capable hardware, pointer devices elsewhere) and rendered
        /// through the renderer's hover paths. Queries run against the SAME
        /// context the verbs use, and never mutate the mesh.
        let hoverPreview = HoverPreviewController()
        /// Journal sink, pushed from `updateUIView`.
        var onCommit: (@MainActor (DocumentCommand) -> Void)?
        /// Chip swap sink (task 3.5), pushed from `updateUIView`.
        var onReplaceCommit: (@MainActor (DocumentCommand, DocumentCommand) -> Bool)?
        /// Live document accessor, pushed from `updateUIView` (journal
        /// integrity): stroke starts re-sync through it so verb
        /// transactions never pin a stale SwiftUI snapshot as `before`.
        var bundleProvider: (@MainActor () -> DocumentBundle)?

        // Retained for tests and for arbitration wiring.
        private(set) var orbitRecognizer: UIPanGestureRecognizer?
        private(set) var pinchRecognizer: UIPinchGestureRecognizer?
        private(set) var twoFingerPanRecognizer: UIPanGestureRecognizer?
        private(set) var doubleTapRecognizer: UITapGestureRecognizer?

        /// Input arbitration (task 3.1, design D5): shared with the editor's
        /// verb toolbar; the observer recognizer feeds it every touch and
        /// every other recognizer is gated through it (`shouldReceive`).
        let inputModel: ViewportInputModel
        var inputController: ViewportInputController { inputModel.controller }
        private(set) var observerRecognizer: TouchObserverRecognizer?
        private(set) var undoTapRecognizers: [UITapGestureRecognizer] = []
        private(set) var hoverRecognizer: UIHoverGestureRecognizer?
        /// Pencil Pro squeeze delivery (task 3.7): squeeze opens the radial
        /// quick-verb palette at the pen tip. Hardware-only — the simulator
        /// never fires it (graceful no-op by construction); everything
        /// below the delegate callback is driven directly in tests and by
        /// the UI-test launch hook.
        private(set) var pencilInteraction: UIPencilInteraction?
        /// Production snap haptics (task 3.7), capability-gated inside the
        /// engine; the mesh editor's `haptics` seam stays injectable.
        private(set) var snapHaptics: SnapHapticsEngine?

        init(
            onUndo: @escaping @MainActor () -> Void,
            onRedo: @escaping @MainActor () -> Void,
            inputModel: ViewportInputModel = ViewportInputModel()
        ) {
            undoCoordinator = UndoGestureView.Coordinator(onUndo: onUndo, onRedo: onRedo)
            self.inputModel = inputModel
        }

        /// Builds the viewport hierarchy: MTKView + undo tap overlay +
        /// camera recognizers. Falls back to a plain placeholder view when
        /// Metal is unavailable (CI without a GPU); the accessibility
        /// identifier AND the undo/redo tap overlay stay in place either
        /// way, so UI tests find the viewport and gesture undo/redo keeps
        /// working without a renderer. `renderer` is injectable so tests
        /// can exercise the fallback.
        func makeView(renderer: ViewportRenderer? = ViewportRenderer()) -> UIView {
            guard let renderer else {
                let fallback = UIView()
                fallback.backgroundColor = .darkGray
                fallback.accessibilityIdentifier = "viewport"
                installUndoOverlay(on: fallback)
                installInputArbitration(on: fallback)
                return fallback
            }
            self.renderer = renderer

            let view = ViewportMetalView(frame: .zero, device: renderer.device)
            view.colorPixelFormat = ViewportRenderer.colorPixelFormat
            view.depthStencilPixelFormat = ViewportRenderer.depthPixelFormat
            view.clearColor = ViewportRenderer.clearColor
            view.clearDepth = 1
            view.delegate = renderer  // weak: self retains the renderer
            view.accessibilityIdentifier = "viewport"

            // Render-on-demand (task 2.5): the view never free-runs; the
            // pacer marks it dirty and paces continuous phases.
            view.isPaused = true
            view.enableSetNeedsDisplay = true
            // MetalFX blits its output into the drawable; only unlock the
            // drawable for blits where that path can actually run.
            view.framebufferOnly = !renderer.capabilities.supportsMetalFXSpatial
            metalView = view

            framePacer.attach(to: view) { [weak renderer] in
                renderer?.isAnimating() ?? false
            }
            renderer.onNeedsDisplay = { [weak framePacer] in
                framePacer?.invalidate()
            }
            view.onDidMoveToWindow = { [weak self, weak view] in
                guard let self, let view, view.window != nil else { return }
                self.framePacer.setPreferredFrameRateRange(
                    displayMaxFPS: view.window?.screen.maximumFramesPerSecond
                        ?? FramePacingPolicy.maxFrameRate
                )
                // Screen scale is only final once on a window: reapply.
                self.reapplyResolutionScale()
                self.framePacer.invalidate()
            }

            installUndoOverlay(on: view)
            installCameraGestures(on: view)
            installInputArbitration(on: view)
            return view
        }

        // MARK: - Resolution scale (task 2.5)

        /// Applies the persisted resolution scale: picks the upscaler for
        /// this device (pure decision), sets the MTKView's content scale
        /// (plain path shrinks the drawable; MetalFX keeps it native and
        /// shrinks the render target), and keeps the renderer's
        /// points→pixels factor in sync so gestures stay in view points.
        func applyResolutionScale(_ scale: Double) {
            guard scale != appliedResolutionScale else { return }
            appliedResolutionScale = scale
            guard let renderer else { return }
            renderer.resolutionScale = scale
            reapplyResolutionScale()
        }

        private func reapplyResolutionScale() {
            guard let renderer, let view = metalView else { return }
            let screenScale =
                view.window?.screen.scale ?? view.traitCollection.displayScale
            let contentScale = ResolutionScalePolicy.contentScaleFactor(
                screenScale: screenScale > 0 ? screenScale : 1,
                resolutionScale: renderer.resolutionScale,
                upscaler: renderer.activeUpscalerKind
            )
            view.desiredContentScale = contentScale
            renderer.contentScale = Float(contentScale)
        }

        /// Mounts the three/four-finger tap undo/redo overlay as the topmost
        /// subview (spec: document-model / "Gesture undo/redo"). Its tap
        /// recognizers are gated through the arbiter (palm rejection: a palm
        /// resting during a pen stroke must not fire undo).
        private func installUndoOverlay(on view: UIView) {
            let undoOverlay = UndoGestureView.makeConfiguredView(coordinator: undoCoordinator)
            undoOverlay.frame = view.bounds
            undoOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(undoOverlay)
            let taps = (undoOverlay.gestureRecognizers ?? [])
                .compactMap { $0 as? UITapGestureRecognizer }
            for tap in taps {
                tap.delegate = self
            }
            undoTapRecognizers = taps
        }

        /// Installs the single touch/Pencil arbiter over the whole viewport
        /// (task 3.1, design D5): one observing recognizer feeds every touch
        /// to the pure `InputArbiter`; pen strokes go to stroke capture,
        /// fingers stay with the camera/undo recognizers, which are
        /// individually gated in `shouldReceive` (authoring is Pencil-only,
        /// task 3.9).
        private func installInputArbitration(on view: UIView) {
            inputController.referenceView = view
            inputController.onCancelCameraGestures = { [weak self] in
                self?.cancelInFlightGestures()
            }
            let observer = TouchObserverRecognizer(controller: inputController)
            observer.delegate = self
            view.addGestureRecognizer(observer)
            observerRecognizer = observer

            // Stage-2 mesh context for the engine recognizer (task 3.2,
            // design D5): fetched at stroke end so every interpretation
            // resolves against the CURRENT EditMesh and the exact camera
            // matrix the user is looking through. Without a renderer
            // (Metal-unavailable fallback) the recognizer stays stage-1.
            inputModel.setRecognizerContext { [weak self] in
                guard let self, let renderer = self.renderer else {
                    return (editMesh: nil, viewProjection: nil, aspect: 1)
                }
                self.resyncFromDocumentIfIdle()
                return (
                    editMesh: self.recognizerEditMesh,
                    viewProjection: renderer.viewProjectionColumns(),
                    aspect: renderer.viewportAspect
                )
            }

            // Verb layer (task 3.3): the mesh-edit controller consumes the
            // stroke events the model forwards, mutates the SAME live mesh
            // handle the overlay/recognizer use, and journals through the
            // document's command path.
            inputModel.meshEditor = meshEditor
            meshEditor.contextProvider = { [weak self] in
                self?.makeEditContext()
            }
            meshEditor.onCommit = { [weak self] command in
                self?.onCommit?(command)
            }
            // Chip alternative swap (task 3.5): the document swaps the last
            // command atomically; its bundle update re-syncs the live mesh
            // through the normal payload/annotation-changed path.
            meshEditor.onReplaceCommit = { [weak self] replacement, expected in
                self?.onReplaceCommit?(replacement, expected) ?? false
            }
            // Coalesced to ONCE PER RENDERED FRAME (not per input sample):
            // brush verbs fire this at up to 240 Hz of coalesced Pencil
            // samples, and every upload rebuilds the invalidated engine
            // render cache (O(mesh)) and runs the geometry pool's reuse
            // fence — a synchronous GPU drain on the main thread. The
            // refresh is parked on the renderer and flushed at the top of
            // the next frame; it reads live state at flush time, so the
            // frame always shows the newest sample's mesh.
            meshEditor.onLiveEdit = { [weak self] in
                guard let self, let renderer = self.renderer else { return }
                if renderer.pendingGeometryRefresh == nil {
                    renderer.pendingGeometryRefresh = { [weak self] in
                        self?.refreshLiveEditGeometry()
                    }
                }
                renderer.invalidate()
            }
            meshEditor.onDiscardLiveEdits = { [weak self] in
                self?.reloadLiveEditMesh()
            }

            // Snap feedback (task 3.7, spec scenario "Snap feedback"): the
            // Tweak/Move merge-snap pre-highlight renders through the same
            // warm-yellow overlay highlight pass as the hover snap target
            // (a stroke clears any hover preview the instant it begins, so
            // the channel is free for the whole drag), and haptic ticks go
            // through the capability-gated engine (simulator: no-op).
            meshEditor.onSnapHighlightChanged = { [weak self] target in
                guard let self, let renderer = self.renderer else { return }
                renderer.setHoverPreview(HoverPreviewGeometry.renderState(
                    for: target.map { HoverPreviewState.Preview.snapTarget($0) },
                    edgeEndpoints: { _ in nil },
                    vertexPosition: { _ in nil }
                ))
            }
            let haptics = SnapHapticsEngine(view: view)
            snapHaptics = haptics
            meshEditor.haptics = haptics

            // Camera-as-manipulator sessions (task 4.2): the session ghost
            // preview renders through the hover ghost channel (transient
            // arrays, pooled copies — same pipeline as the task-3.6 hint),
            // and hover previews are suppressed while a session is armed
            // so the two never fight over it.
            meshEditor.onSessionPreviewChanged = { [weak self] ghost in
                guard let renderer = self?.renderer else { return }
                renderer.setHoverPreview(HoverRenderState(
                    ghost: ghost, highlight: nil
                ))
            }

            installHoverPreview(on: view)
            installPencilInteraction(on: view)
        }

        /// Feeds the applied camera pose into the armed tool session —
        /// but ONLY when the arbiter's camera→tool gate is open (task
        /// 4.2, design D5: while a camera-as-manipulator session is
        /// armed, camera input BOTH moves the camera AND drives the tool;
        /// the arbiter owns that verdict, this method never bypasses it).
        func feedCameraToArmedTool() {
            guard inputController.cameraFeedsArmedTool, let renderer else { return }
            meshEditor.cameraPoseChanged(camera: renderer.camera)
        }

        /// Pencil Pro squeeze (task 3.7): `UIPencilInteraction` delivers
        /// squeezes on supporting hardware only; the delegate maps the
        /// user's SYSTEM squeeze preference to the quick-verb palette
        /// policy. Barrel roll rides on the hover recognizer (see
        /// `handleHover`), not on this interaction.
        private func installPencilInteraction(on view: UIView) {
            let interaction = UIPencilInteraction(delegate: self)
            view.addInteraction(interaction)
            pencilInteraction = interaction
        }

        /// Everything the verb layer AND the hover previews need, fetched
        /// fresh per event. Journal integrity: the coordinator's snapshot is
        /// only refreshed by SwiftUI update passes, but this context is
        /// fetched from touch/hover handling that can drain BEFORE the next
        /// pass (pen-down queued behind a commit or an undo tap in the same
        /// runloop drain). Re-sync from the live document first so verb
        /// transactions pin the true current payload as `before` and every
        /// consumer sees current state.
        /// Internal (not private) so the task-4.3 annotation tests can
        /// journal against the SAME context the verb layer uses.
        func makeEditContext() -> MeshEditController.Context? {
            guard let renderer else { return nil }
            resyncFromDocumentIfIdle()
            return MeshEditController.Context(
                editObject: editObject,
                editMesh: recognizerEditMesh,
                editPayload: overlayPayload,
                documentHasEditMesh: documentHasEditMesh,
                annotations: editObject?.annotations,
                symmetry: documentSymmetry,
                snapper: targetSnapper,
                sceneRadius: renderer.bounds.radius,
                ray: { [weak renderer] point in
                    renderer?.cameraRay(atNormalizedPoint: point)
                },
                project: { [weak renderer] world in
                    guard let renderer else { return nil }
                    return ScreenRay.normalizedPoint(
                        of: world, viewProjectionColumns: renderer.viewProjectionColumns()
                    )
                },
                camera: renderer.camera,
                cameraFeedsArmedTool: inputController.cameraFeedsArmedTool,
                orbitCamera: { [weak renderer] delta in
                    renderer?.orbit(byPoints: delta)
                }
            )
        }

        /// Hover previews (task 3.6, spec: pencil-interaction / "Hover
        /// gesture preview"): a `UIHoverGestureRecognizer` feeds the hover
        /// controller — Apple Pencil hover on hover-capable iPads, trackpad
        /// /mouse pointers elsewhere; actual Pencil hover delivery is
        /// hardware-only (device test plan, task 9.6). The queries resolve
        /// through `makeEditContext` (read-only engine queries; the mesh is
        /// never modified), and a beginning stroke clears any preview
        /// instantly so it cannot linger under live authoring.
        private func installHoverPreview(on view: UIView) {
            hoverPreview.contextProvider = { [weak self] in
                self?.makeEditContext()
            }
            hoverPreview.onRenderStateChanged = { [weak self] state in
                self?.renderer?.setHoverPreview(state)
            }
            // Loop Info inspector (task 4.3): the measurement runs through
            // the mesh-edit controller's engine query (O(loop), read-only)
            // and surfaces as a chip on the input model.
            hoverPreview.loopInfoProvider = { [weak self] point, context in
                self?.meshEditor.loopInfo(at: point, in: context)
            }
            hoverPreview.onLoopInfoChanged = { [weak self] info in
                self?.inputModel.setLoopInfo(info)
            }
            inputModel.onStrokeWillBegin = { [weak self] in
                self?.hoverPreview.strokeBegan()
            }
            inputModel.hoverPreview = hoverPreview
            let hover = UIHoverGestureRecognizer(
                target: self, action: #selector(handleHover)
            )
            view.addGestureRecognizer(hover)
            hoverRecognizer = hover
        }

        @objc func handleHover(_ recognizer: UIHoverGestureRecognizer) {
            guard
                let view = recognizer.view,
                view.bounds.width > 0, view.bounds.height > 0
            else { return }
            switch recognizer.state {
            case .began, .changed:
                let location = recognizer.location(in: view)
                // Hover previews pause while a camera-as-manipulator
                // session is armed (task 4.2): the session's ghost preview
                // owns the hover ghost channel for its duration.
                if meshEditor.cameraSession == nil {
                    hoverPreview.hoverChanged(at: SIMD2(
                        Float(location.x / view.bounds.width),
                        Float(location.y / view.bounds.height)
                    ))
                }
                // Pencil Pro barrel roll (task 3.7): non-zero only on
                // hardware that reports it; forwarded into the model's
                // rotate-placed-element hook (first real consumer is the
                // 4.2 placement tools — see tasks.md 3.7a).
                inputModel.barrelRollChanged(Float(recognizer.rollAngle))
            default:
                hoverPreview.hoverEnded()
            }
        }

        /// Pen priority: the pen landed while finger gestures were in
        /// flight — reset every non-observer recognizer so a resting palm
        /// cannot keep steering the camera or complete an undo tap.
        private func cancelInFlightGestures() {
            let cameraRecognizers: [UIGestureRecognizer?] = [
                orbitRecognizer, pinchRecognizer, twoFingerPanRecognizer, doubleTapRecognizer,
            ]
            var recognizers: [UIGestureRecognizer] = cameraRecognizers.compactMap { $0 }
            recognizers.append(contentsOf: undoTapRecognizers)
            for recognizer in recognizers {
                recognizer.isEnabled = false
                recognizer.isEnabled = true
            }
        }

        private func installCameraGestures(on view: UIView) {
            let orbit = UIPanGestureRecognizer(target: self, action: #selector(handleOrbit))
            orbit.minimumNumberOfTouches = 1
            orbit.maximumNumberOfTouches = 1

            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
            let twoFingerPan = UIPanGestureRecognizer(
                target: self, action: #selector(handleTwoFingerPan)
            )
            twoFingerPan.minimumNumberOfTouches = 2
            twoFingerPan.maximumNumberOfTouches = 2

            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
            doubleTap.numberOfTapsRequired = 2
            doubleTap.numberOfTouchesRequired = 1

            // Deliberate arbitration (see type comment): pinch and two-finger
            // pan may run simultaneously (natural zoom+pan camera feel); the
            // three/four-finger undo taps need no explicit requirement against
            // pinch/pan because taps complete within the movement slop that
            // pans/pinches need to even begin. All four are delegated so the
            // InputArbiter can veto touches per recognizer (`shouldReceive`:
            // pencil never drives the camera, palm rejection while the pen
            // is down, 3rd+ finger never admitted to camera gestures).
            for recognizer in [orbit, pinch, twoFingerPan, doubleTap] {
                recognizer.delegate = self
                view.addGestureRecognizer(recognizer)
            }
            orbitRecognizer = orbit
            pinchRecognizer = pinch
            twoFingerPanRecognizer = twoFingerPan
            doubleTapRecognizer = doubleTap
        }

        /// (Re)loads the render mesh, Target snapper, and EditMesh overlay
        /// when the document changed. Change detection is per concern:
        /// mesh edits (task 3.3) touch only the EditMesh payload, so the
        /// solid Target render — and the camera — stay put.
        func syncMesh(from bundle: DocumentBundle) {
            guard let renderer else { return }
            syncRenderMesh(from: bundle, renderer: renderer)
            syncTargetSnapper(from: bundle)
            syncOverlay(from: bundle, renderer: renderer)
            syncSymmetry(from: bundle, renderer: renderer)
            inputModel.setSceneBounds(
                center: renderer.bounds.center, radius: renderer.bounds.radius
            )
        }

        /// Mirrors the document's symmetry state (task 4.4) into the
        /// viewport: the plane rim the renderer draws, and the value every
        /// authoring context reads. Symmetry is DOCUMENT state, so undoing
        /// a `setSymmetry` command re-enters here and puts the rim back.
        private func syncSymmetry(from bundle: DocumentBundle, renderer: ViewportRenderer) {
            let settings = bundle.manifest.symmetry
            guard settings != documentSymmetry else { return }
            documentSymmetry = settings
            renderer.setOverlaySymmetry(settings ?? SymmetrySettings())
        }

        /// Re-syncs the viewport state from the CURRENT document (via
        /// `bundleProvider`) unless a brush session is mid-stroke. Called
        /// when a stroke needs document state (stroke begin / pencil apply /
        /// recognizer stage 2) because those run off touch handling, which
        /// can drain before the SwiftUI update pass that normally refreshes
        /// the snapshot. The session guard matters: at brush-stroke end the
        /// live mesh intentionally runs AHEAD of the document (uncommitted
        /// edits) — reloading it from the payload would discard them.
        func resyncFromDocumentIfIdle() {
            guard !meshEditor.isSessionActive, let bundle = bundleProvider?() else { return }
            syncMesh(from: bundle)
        }

        private func syncRenderMesh(from bundle: DocumentBundle, renderer: ViewportRenderer) {
            let object = MetalViewport.renderableObject(in: bundle.manifest)
            let payload = object.flatMap { bundle.payloads[$0.payloadFile] }
            guard object?.id != renderedObjectID || payload != renderedPayload else { return }
            // A payload-only change of the SAME object is a mesh edit:
            // update the geometry without snapping the camera back to
            // frame-to-fit.
            let sameObject = object != nil && object?.id == renderedObjectID
            renderedObjectID = object?.id
            renderedPayload = payload
            if let object, let mesh = try? bundle.mesh(for: object) {
                renderer.load(mesh: mesh, preservingCamera: sameObject)
            } else {
                renderer.clearMesh()
            }
        }

        /// Builds the Target surface snapper (task 3.3: continuous snap
        /// projection for every verb). Targets are immutable, so the
        /// object's identity is the only change signal.
        private func syncTargetSnapper(from bundle: DocumentBundle) {
            let target = bundle.manifest.objects.first { $0.role == .target }
            guard target?.id != targetObjectID else { return }
            targetObjectID = target?.id
            guard let target, let mesh = try? bundle.mesh(for: target) else {
                targetMesh = nil
                targetSnapper = nil
                return
            }
            targetMesh = mesh
            targetSnapper = try? SurfaceSnapper(target: mesh)
        }

        /// Loads the first EditMesh into the wireframe overlay pipeline
        /// (task 2.3) and (re)binds the live mesh handle the recognizer and
        /// the verbs share. The creation animation restarts only for a new
        /// EditMesh object; payload changes (mesh edits, undo/redo) reload
        /// silently.
        private func syncOverlay(from bundle: DocumentBundle, renderer: ViewportRenderer) {
            let object = bundle.manifest.objects.first { $0.role == .editMesh }
            documentHasEditMesh = object != nil
            let payload = object.flatMap { bundle.payloads[$0.payloadFile] }
            // Externally-driven EditMesh change landing MID-BRUSH-STROKE
            // (e.g. an iCloud conflict revert reloading the document while
            // a relax scrub is in flight): the session still holds the old
            // mesh handle and its pinned before-payload, so later samples
            // would mutate an orphaned handle (edits stop rendering) and
            // the stroke-end commit would journal a `before` the document
            // no longer contains — reverting it would restore pre-reload
            // bytes instead of the document's actual prior state. The
            // external reload wins: cancel the session (discarding its
            // live edits) before rebinding the snapshot. A mid-stroke pass
            // with an UNCHANGED document (the normal SwiftUI update) never
            // triggers this — object identity and payload bytes match the
            // pinned snapshot, and mid-session the document payload only
            // moves via this coordinator's own commits, which end the
            // session first.
            if meshEditor.isSessionActive,
                object?.id != overlayObjectID || payload != overlayPayload {
                meshEditor.strokeCancelled()
            }
            // Camera-as-manipulator sessions (task 4.2): the session's own
            // commit (a Patch Clone paste) re-pins and stays armed for the
            // next paste; any EXTERNAL snapshot change invalidates the
            // selection ids and discards the session. The live mesh is
            // rebound below either way, so no separate discard is needed.
            if object?.id != overlayObjectID || payload != overlayPayload {
                meshEditor.editMeshSnapshotWillChange(payload: payload)
            }
            guard let object, let payload else {
                overlayObjectID = nil
                overlayPayload = nil
                editObject = nil
                overlayAnnotations = nil
                recognizerEditMesh = nil
                renderer.clearOverlay()
                rebuildSubdivisionPreview(duringStroke: false)
                return
            }
            let isNewObject = object.id != overlayObjectID
            let payloadChanged = payload != overlayPayload
            editObject = object  // counts/revision may move without a reload
            guard isNewObject || payloadChanged else {
                // Annotation-only change (loop tag / hide / show commands,
                // task 3.4): payload bytes are untouched, so refresh just
                // the live handle's render filters and the overlay upload.
                if object.annotations != overlayAnnotations,
                    let mesh = recognizerEditMesh {
                    overlayAnnotations = object.annotations
                    try? mesh.applyAnnotations(object.annotations)
                    renderer.loadOverlay(
                        mesh: mesh, annotations: object.annotations,
                        restartAnimation: false)
                    if renderedObjectID == overlayObjectID {
                        renderer.load(mesh: mesh, preservingCamera: true)
                    }
                }
                return
            }
            guard let mesh = try? Mesh(payloadData: payload) else {
                // Deserialize failure: clear ALL four snapshot fields —
                // leaving `editObject` set would break the one-consistent-
                // snapshot invariant (brush verbs must go inert, and the
                // pencil fallback must not treat this as "no EditMesh").
                overlayObjectID = nil
                overlayPayload = nil
                editObject = nil
                overlayAnnotations = nil
                recognizerEditMesh = nil
                renderer.clearOverlay()
                rebuildSubdivisionPreview(duringStroke: false)
                return
            }
            overlayObjectID = object.id
            overlayPayload = payload
            overlayAnnotations = object.annotations
            try? mesh.applyAnnotations(object.annotations)
            recognizerEditMesh = mesh
            renderer.loadOverlay(
                mesh: mesh, annotations: object.annotations, restartAnimation: isNewObject)
            // The base cage changed in the DOCUMENT (a commit, an undo, an
            // import): the preview must follow it exactly, throttle or not.
            rebuildSubdivisionPreview(duringStroke: false)
        }

        /// Uploads the CURRENT live EditMesh into the overlay (and, for a
        /// target-less document, the solid) pipeline. Runs at most once per
        /// rendered frame via `ViewportRenderer.pendingGeometryRefresh` —
        /// see `meshEditor.onLiveEdit` for why it is never called per
        /// input sample.
        private func refreshLiveEditGeometry() {
            guard let renderer, let mesh = recognizerEditMesh else { return }
            renderer.loadOverlay(
                mesh: mesh, annotations: overlayAnnotations, restartAnimation: false)
            // A target-less document renders the EditMesh solid too.
            if renderedObjectID == overlayObjectID {
                renderer.load(mesh: mesh, preservingCamera: true)
            }
            // Live subdivision preview (task 4.6, spec scenario "Editing
            // under preview"): re-derived on the SAME once-per-rendered-
            // frame hook as the wireframe, so the smoothed surface tracks
            // the base cage through a drag without the derivation ever
            // running per input sample. `duringStroke` engages the cost
            // guard — see `SubdivisionPreviewPolicy`.
            rebuildSubdivisionPreview(duringStroke: meshEditor.isSessionActive)
        }

        // MARK: - Subdivision preview (task 4.6)

        /// Requested preview level (a DISPLAY preference pushed from the
        /// viewport settings popover — never document state).
        private(set) var subdivisionPreviewLevel: SubdivisionPreviewLevel = .off
        /// The derived preview mesh currently uploaded, retained so tests
        /// can assert what the preview contains versus what the document
        /// stores. Derived render data ONLY: never journaled, never written
        /// into the bundle, never exported.
        private(set) var subdivisionPreviewMesh: Mesh?
        /// How many times the preview has actually been re-derived. The
        /// throttle policy's observable: a skipped live rebuild leaves this
        /// unchanged while the previous preview stays on screen.
        private(set) var subdivisionPreviewRebuildCount = 0
        /// When the last MID-STROKE rebuild ran, for the rate guard
        /// (`SubdivisionPreviewPolicy.minimumLiveRebuildInterval`). Cleared
        /// on every non-stroke rebuild so a fresh stroke starts responsive.
        private var lastLivePreviewRebuild: Date?
        /// Seam for the ONE branch that is otherwise unreachable from a
        /// test: the derivation throwing. `Mesh.subdivisionPreview` is a
        /// filesystem round trip, so it fails transiently in the field (low
        /// disk, sandbox pressure) and never on demand. Nil in the app —
        /// the real derivation runs — and set by the regression test that
        /// pins "a mid-stroke failure skips, it does not clear".
        var subdivisionPreviewDeriver: (
            (Mesh, SubdivisionPreviewLevel, SurfaceSnapper?) throws -> Mesh
        )?

        /// Applies a new preview level. Idempotent — an unchanged level
        /// never re-derives, so the SwiftUI update pass that runs on every
        /// unrelated state change costs nothing.
        func setSubdivisionPreviewLevel(_ level: SubdivisionPreviewLevel) {
            guard level != subdivisionPreviewLevel else { return }
            subdivisionPreviewLevel = level
            // A level change is a user action, not a mid-stroke sample:
            // rebuild unconditionally so the control responds even on a
            // cage the cost guard would throttle during a drag.
            rebuildSubdivisionPreview(duringStroke: false)
        }

        /// Re-derives and uploads the preview from the CURRENT base cage.
        ///
        /// Non-destructive by construction: `Mesh.subdivisionPreview` works
        /// on a copy, so `recognizerEditMesh` — the handle the recognizer
        /// resolves against and every verb mutates — is only ever READ here.
        ///
        /// `duringStroke` selects the throttle branch documented on
        /// `SubdivisionPreviewPolicy`: below the face budget every live edit
        /// rebuilds; above it, mid-stroke rebuilds are skipped and the last
        /// preview stays visible until the stroke ends (both stroke-end
        /// paths — commit through `syncOverlay`, cancel through
        /// `reloadLiveEditMesh` — call back in with `duringStroke: false`).
        func rebuildSubdivisionPreview(duringStroke: Bool) {
            guard let renderer else { return }
            guard let base = recognizerEditMesh, subdivisionPreviewLevel != .off else {
                subdivisionPreviewMesh = nil
                lastLivePreviewRebuild = nil
                renderer.clearSubdivisionPreview()
                return
            }
            guard SubdivisionPreviewPolicy.allowsRebuild(
                baseFaces: base.faceCount, level: subdivisionPreviewLevel,
                duringStroke: duringStroke
            ) else { return }
            // RATE GUARD: the derivation is a filesystem round trip plus a
            // BVH reprojection on the main actor — it must not run once per
            // rendered frame on a 120 Hz display just because it fits the
            // face budgets. Stroke-end rebuilds bypass this entirely, so
            // what the user is left looking at is always exact.
            if duringStroke {
                guard SubdivisionPreviewPolicy.shouldRebuildNow(since: lastLivePreviewRebuild)
                else { return }
                lastLivePreviewRebuild = Date()
            } else {
                lastLivePreviewRebuild = nil
            }
            let derive = subdivisionPreviewDeriver ?? {
                try $0.subdivisionPreview(level: $1, reprojectingOnto: $2)
            }
            guard let preview = try? derive(
                base, subdivisionPreviewLevel, targetSnapper
            ) else {
                // MID-STROKE FAILURE IS A SKIP, NOT A CLEAR. The derivation
                // is a filesystem round trip (`detachedCopy` writes and
                // reads OBJ through the temporary directory) and can throw
                // transiently — low disk, sandbox pressure. Wiping the
                // preview here made the smoothed surface VANISH mid-drag,
                // the exact opposite of the policy documented on
                // `SubdivisionPreviewPolicy`: the previously derived preview
                // stays on screen until the stroke ends. It is slightly
                // stale, which is what a throttled preview always is; it is
                // never wrong-looking. The rate stamp is deliberately KEPT,
                // so a repeating failure retries on the normal 50 ms cadence
                // instead of hammering a failing filesystem every frame, and
                // the stroke-end rebuild below re-derives exactly.
                if duringStroke { return }
                subdivisionPreviewMesh = nil
                renderer.clearSubdivisionPreview()
                return
            }
            subdivisionPreviewRebuildCount += 1
            subdivisionPreviewMesh = preview
            renderer.loadSubdivisionPreview(mesh: preview)
        }

        /// Reloads the live EditMesh from the pinned document payload —
        /// the discard path for cancelled/failed verb strokes (task 3.3).
        private func reloadLiveEditMesh() {
            guard let renderer else { return }
            guard let payload = overlayPayload, let mesh = try? Mesh(payloadData: payload)
            else {
                recognizerEditMesh = nil
                renderer.clearOverlay()
                rebuildSubdivisionPreview(duringStroke: false)
                return
            }
            try? mesh.applyAnnotations(overlayAnnotations)
            recognizerEditMesh = mesh
            renderer.loadOverlay(
                mesh: mesh, annotations: overlayAnnotations, restartAnimation: false)
            // Stroke-end (cancel/discard) path: the throttle never applies
            // here, so a cage above the live budget still ends up showing
            // an EXACT preview of what the user is left with.
            rebuildSubdivisionPreview(duringStroke: false)
        }

        /// DEBUG-only demo path for task 2.4: mirrors the first EditMesh
        /// into the ghost pipeline (small normal-offset, pulsing translucent
        /// style) so the ghost render style is visually verifiable before
        /// the Weave solver (phase 5) produces real proposals. Reloads only
        /// when toggled on/off, when the EditMesh object changes, or when
        /// its payload changes (mesh edits, undo/redo) — and deserializes
        /// only when a reload is actually due, never on every update pass.
        func syncGhostPreview(from bundle: DocumentBundle, enabled: Bool) {
            guard let renderer else { return }
            let editMesh = bundle.manifest.objects.first { $0.role == .editMesh }
            let payload = editMesh.flatMap { bundle.payloads[$0.payloadFile] }
            guard enabled, let editMesh, let payload else {
                clearGhostPreview(renderer: renderer)
                return
            }
            guard editMesh.id != ghostPreviewObjectID || payload != ghostPreviewPayload
            else { return }
            guard let mesh = try? Mesh(payloadData: payload) else {
                clearGhostPreview(renderer: renderer)
                return
            }
            ghostPreviewObjectID = editMesh.id
            ghostPreviewPayload = payload
            renderer.ghostStyle = .debugPreview(sceneRadius: renderer.bounds.radius)
            renderer.loadGhost(mesh: mesh)
        }

        private func clearGhostPreview(renderer: ViewportRenderer) {
            guard ghostPreviewObjectID != nil else { return }
            ghostPreviewObjectID = nil
            ghostPreviewPayload = nil
            renderer.clearGhost()
        }

        // MARK: - Gesture handlers

        /// Continuous camera gestures pin the display link (up to 120 Hz on
        /// ProMotion) for their whole lifetime; the camera mutations
        /// themselves invalidate per change.
        private func trackInteraction(_ state: UIGestureRecognizer.State) {
            switch state {
            case .began:
                framePacer.beginInteraction()
            case .ended, .cancelled, .failed:
                framePacer.endInteraction()
            default:
                break
            }
        }

        @objc func handleOrbit(_ recognizer: UIPanGestureRecognizer) {
            trackInteraction(recognizer.state)
            let translation = recognizer.translation(in: recognizer.view)
            recognizer.setTranslation(.zero, in: recognizer.view)
            renderer?.orbit(byPoints: SIMD2(Float(translation.x), Float(translation.y)))
            feedCameraToArmedTool()
        }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            trackInteraction(recognizer.state)
            renderer?.zoom(byPinchScale: Float(recognizer.scale))
            recognizer.scale = 1
            feedCameraToArmedTool()
        }

        @objc func handleTwoFingerPan(_ recognizer: UIPanGestureRecognizer) {
            trackInteraction(recognizer.state)
            let translation = recognizer.translation(in: recognizer.view)
            recognizer.setTranslation(.zero, in: recognizer.view)
            renderer?.pan(byPoints: SIMD2(Float(translation.x), Float(translation.y)))
            feedCameraToArmedTool()
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            // Animated reframe: the pacer keeps drawing while the camera
            // animation runs (renderer.isAnimating), no interaction pin
            // needed for a discrete tap.
            renderer?.reframe(animated: true)
        }
    }
}

/// MTKView subclass that pins a chosen `contentScaleFactor` (the resolution
/// -scale mechanism, task 2.5). UIKit resets the scale to the screen's when
/// the view joins a window, so the desired value is reapplied there.
final class ViewportMetalView: MTKView {
    /// The content scale the resolution-scale policy chose; nil = leave
    /// UIKit's default alone.
    var desiredContentScale: CGFloat? {
        didSet { applyDesiredContentScale() }
    }

    var onDidMoveToWindow: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyDesiredContentScale()
        onDidMoveToWindow?()
    }

    private func applyDesiredContentScale() {
        guard let desiredContentScale, desiredContentScale > 0,
            contentScaleFactor != desiredContentScale
        else { return }
        contentScaleFactor = desiredContentScale
    }
}

extension MetalViewport.Coordinator: UIGestureRecognizerDelegate {
    /// Only pinch + two-finger pan combine; everything else stays exclusive.
    /// The touch observer pairs with everything: it never recognizes, and
    /// exempting it here keeps UIKit from force-failing it mid-gesture (the
    /// arbiter would stop seeing touch end events).
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        let pair = [gestureRecognizer, other]
        if pair.contains(where: { $0 === observerRecognizer }) { return true }
        return pair.contains { $0 === pinchRecognizer }
            && pair.contains { $0 === twoFingerPanRecognizer }
    }

    /// Central routing gate (task 3.1, design D5): every recognizer asks the
    /// arbiter before accepting a touch.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch
    ) -> Bool {
        inputController.shouldReceive(touch, for: gate(for: gestureRecognizer))
    }

    private func gate(for recognizer: UIGestureRecognizer) -> ViewportInputController.RecognizerGate {
        if recognizer === observerRecognizer { return .observer }
        if undoTapRecognizers.contains(where: { $0 === recognizer }) { return .undoTap }
        return .camera
    }
}

// MARK: - Pencil Pro squeeze (task 3.7)

extension MetalViewport.Coordinator: UIPencilInteractionDelegate {
    /// Squeeze completed: open/dismiss the radial quick-verb palette at
    /// the pen tip (spec: "Pencil Pro squeeze SHALL open a radial Action
    /// Gallery at the pen tip"; the minimal five-verb ring — the full
    /// gallery is task 3.8). The user's SYSTEM squeeze preference is
    /// honored via the pure policy mapping below.
    func pencilInteraction(
        _ interaction: UIPencilInteraction,
        didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze
    ) {
        guard squeeze.phase == .ended else { return }
        var location: SIMD2<Float>?
        if let view = interaction.view, let pose = squeeze.hoverPose,
            view.bounds.width > 0, view.bounds.height > 0 {
            let point = pose.location
            location = SIMD2(
                Float(point.x / view.bounds.width),
                Float(point.y / view.bounds.height)
            )
        }
        inputModel.pencilSqueezed(
            action: QuickVerbPaletteState.SqueezeAction(
                systemPreference: UIPencilInteraction.preferredSqueezeAction
            ),
            atNormalized: location
        )
    }
}

extension QuickVerbPaletteState.SqueezeAction {
    /// Maps the user's system-wide squeeze preference to the app policy:
    /// `.ignore` is honored verbatim, `.switchEraser` selects the Erase
    /// verb, and every palette-flavored preference opens the quick-verb
    /// ring — the app's only contextual palette (it has no ink/color
    /// attributes to show). `.switchPrevious` is honestly ignored until
    /// the arbiter tracks a previous-verb history.
    init(systemPreference: UIPencilPreferredAction) {
        switch systemPreference {
        case .ignore, .switchPrevious:
            self = .ignore
        case .switchEraser:
            self = .selectEraser
        case .showContextualPalette, .showColorPalette, .showInkAttributes,
            .runSystemShortcut:
            self = .showPalette
        @unknown default:
            self = .showPalette
        }
    }
}

/// Persisted viewport interaction settings (spec: "orbit/zoom speed SHALL be
/// user-adjustable"). Backed by `@AppStorage` at the call site.
enum ViewportSettings {
    static let orbitSpeedKey = "viewportOrbitSpeed"
    static let zoomSpeedKey = "viewportZoomSpeed"
    static let defaultSpeed = 1.0
    static let speedRange = 0.2...3.0

    // EditMesh overlay (task 2.3, spec: configurable opacity, occlusion
    // depth threshold, x-ray mode).
    static let overlayOpacityKey = "editMeshOverlayOpacity"
    static let xrayKey = "viewportXRayEnabled"
    static let occlusionBiasKey = "overlayOcclusionBias"
    static let defaultOverlayOpacity = 0.85
    static let overlayOpacityRange = 0.0...1.0
    /// Occlusion threshold in NDC depth units (0 = hard occlusion at the
    /// surface, upper bound keeps the wireframe from bleeding through the
    /// whole model).
    static let defaultOcclusionBias = 0.002
    static let occlusionBiasRange = 0.0...0.02

    /// DEBUG-only ghost preview toggle (task 2.4 demo path; the real ghost
    /// feed arrives with the Weave solver in phase 5).
    static let ghostDebugKey = "viewportGhostDebugPreview"

    /// Left-handed mirror stub (task 3.1; spec: "Hold-chord spring-loaded
    /// modifiers" — left-handed mode SHALL be supported). For now it mirrors
    /// the minimal verb toolbar to the trailing edge; full repositioning
    /// lands with the customizable toolbar (task 3.8).
    static let leftHandedToolbarKey = "leftHandedToolbar"

    /// Snap haptics toggle (task 3.7; spec: "haptics SHALL be
    /// user-disableable"). Off silences the merge-snap ticks only — the
    /// snap-target pre-highlight and the merge behavior are unaffected.
    static let snapHapticsKey = "snapHapticsEnabled"

    /// DEBUG-only recognizer HUD (task 3.2, design D5: "interpretation
    /// records + debug HUD from day one"): overlays the last stroke's
    /// polyline and its full interpretation record on the viewport. The
    /// toggle only appears in DEBUG builds of the settings popover.
    static let strokeDebugHUDKey = "strokeDebugHUD"

    // Performance controls (task 2.5, spec: "Performance controls"):
    // resolution scale for battery/thermals; MetalFX upscaling engages
    // automatically below 100% where the device supports it.
    static let resolutionScaleKey = "viewportResolutionScale"
    static let defaultResolutionScale = 1.0
    static let resolutionScaleOptions: [Double] = [0.5, 0.75, 1.0]

    /// Auto Relax mode (task 4.5, spec: retopology-tools / "Auto Relax" —
    /// "An OPTIONAL Auto Relax mode"). A persisted app preference, not
    /// document state: it changes how the next edit behaves for this user,
    /// and its effect on the document is already inside the journaled
    /// command of the operation that triggered it. Off by default.
    static let autoRelaxKey = "autoRelaxEnabled"

    /// Subdivision preview level (task 4.6, spec: retopology-tools /
    /// "Subdivision preview"). A persisted DISPLAY preference, not document
    /// state: it changes only what this user sees, never what is stored,
    /// journaled or exported. Off by default.
    static let subdivisionPreviewKey = "subdivisionPreviewLevel"
    static let defaultSubdivisionPreviewLevel = 0
    static let subdivisionPreviewLevels: [Int] = [0, 1, 2]
}

/// Popover content adjusting the persisted camera speeds and EditMesh
/// overlay display options (identifiers live on leaf controls — see the
/// container-identifier accessibility trap noted on `objectList`).
struct ViewportSettingsView: View {
    @Binding var orbitSpeed: Double
    @Binding var zoomSpeed: Double
    @Binding var overlayOpacity: Double
    @Binding var xrayEnabled: Bool
    @Binding var occlusionBias: Double
    @Binding var ghostDebugEnabled: Bool
    @Binding var resolutionScale: Double
    @Binding var leftHandedToolbar: Bool
    @Binding var snapHapticsEnabled: Bool
    @Binding var strokeDebugHUD: Bool
    /// Subdivision preview level (task 4.6): 0 / 1 / 2.
    @Binding var subdivisionPreviewLevel: Int
    /// Whether the document has a Target to reproject the preview onto —
    /// drives the HONEST caption below the control.
    var hasTarget = false
    /// Symmetry (task 4.4) is DOCUMENT state, not an `AppStorage`
    /// preference: it arrives as a value and leaves through `onSymmetry`,
    /// which the editor journals.
    var symmetry: SymmetrySettings = SymmetrySettings()
    var sceneCenter: SIMD3<Float> = .zero
    var sceneRadius: Float = 1
    var onSymmetryChange: (SymmetrySettings) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Camera")
                .font(.headline)
            LabeledContent("Orbit speed") {
                Slider(value: $orbitSpeed, in: ViewportSettings.speedRange)
                    .frame(width: 180)
                    .accessibilityIdentifier("orbit-speed-slider")
            }
            LabeledContent("Zoom speed") {
                Slider(value: $zoomSpeed, in: ViewportSettings.speedRange)
                    .frame(width: 180)
                    .accessibilityIdentifier("zoom-speed-slider")
            }
            Button("Reset to Defaults") {
                orbitSpeed = ViewportSettings.defaultSpeed
                zoomSpeed = ViewportSettings.defaultSpeed
            }
            .accessibilityIdentifier("reset-camera-speeds")

            Divider()

            Text("EditMesh Wireframe")
                .font(.headline)
            LabeledContent("Opacity") {
                Slider(value: $overlayOpacity, in: ViewportSettings.overlayOpacityRange)
                    .frame(width: 180)
                    .accessibilityIdentifier("wireframe-opacity-slider")
            }
            LabeledContent("Occlusion depth") {
                Slider(value: $occlusionBias, in: ViewportSettings.occlusionBiasRange)
                    .frame(width: 180)
                    .accessibilityIdentifier("occlusion-depth-slider")
            }
            Toggle("X-ray mode", isOn: $xrayEnabled)
                .accessibilityIdentifier("xray-toggle")

            Divider()

            // Subdivision preview (task 4.6): a non-destructive DISPLAY
            // level. Editing always continues on the base cage, and the
            // wireframe above keeps drawing that cage over the smoothed
            // surface — that stacking is the retopology workflow.
            Text("Subdivision Preview")
                .font(.headline)
            LabeledContent("Level") {
                Picker("Subdivision preview", selection: $subdivisionPreviewLevel) {
                    ForEach(ViewportSettings.subdivisionPreviewLevels, id: \.self) { level in
                        Text(SubdivisionPreviewLevel(clamping: level).label).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .accessibilityIdentifier("subdivision-preview-picker")
            }
            Text(subdivisionPreviewCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 300, alignment: .leading)

            Divider()

            // Input (task 3.1): left-handed mirror stub — moves the verb
            // toolbar to the trailing edge (full repositioning is task 3.8).
            Text("Input")
                .font(.headline)
            Toggle("Left-handed toolbar", isOn: $leftHandedToolbar)
                .accessibilityIdentifier("left-handed-toggle")
            // Task 3.7 (spec: "haptics SHALL be user-disableable"): off
            // silences snap/merge ticks; the pre-highlight and the merge
            // behavior itself are unaffected.
            Toggle("Snap haptics", isOn: $snapHapticsEnabled)
                .accessibilityIdentifier("snap-haptics-toggle")

            Divider()

            SymmetrySettingsView(
                settings: symmetry,
                sceneCenter: sceneCenter,
                sceneRadius: sceneRadius,
                onChange: onSymmetryChange
            )

            Divider()

            // Performance controls (task 2.5): drawable resolution only —
            // UI chrome stays at native scale and gestures are unaffected.
            Text("Performance")
                .font(.headline)
            LabeledContent("Resolution") {
                Picker("Resolution", selection: $resolutionScale) {
                    ForEach(ViewportSettings.resolutionScaleOptions, id: \.self) { option in
                        Text("\(Int((option * 100).rounded()))%").tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .accessibilityIdentifier("resolution-scale-picker")
            }
            Text("Below 100%, MetalFX upscaling is used where supported.")
                .font(.caption)
                .foregroundStyle(.secondary)

            #if DEBUG
                // Debug-only (task 2.4 demo path): compiled out of Release.
                Divider()

                Text("Debug")
                    .font(.headline)
                Toggle("Ghost preview (DEBUG)", isOn: $ghostDebugEnabled)
                    .accessibilityIdentifier("ghost-debug-toggle")
                // Recognizer HUD (task 3.2): last stroke polyline +
                // interpretation record over the viewport.
                Toggle("Stroke recognizer HUD (DEBUG)", isOn: $strokeDebugHUD)
                    .accessibilityIdentifier("stroke-debug-toggle")
                Text(
                    """
                    Development aid: renders the EditMesh as ghost geometry \
                    until the Weave solver (phase 5) produces real proposals.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 300, alignment: .leading)
            #endif
        }
        .padding()
        .frame(minWidth: 300)
    }

    /// Honest caption for the preview control (task 4.6). The engine has
    /// LINEAR subdivision only, so the smoothing comes entirely from
    /// reprojecting onto the Target — with no Target the preview is just a
    /// denser cage, and the UI says exactly that rather than implying a
    /// smooth-subdivision surface the engine cannot produce.
    private var subdivisionPreviewCaption: String {
        let level = SubdivisionPreviewLevel(clamping: subdivisionPreviewLevel)
        if level == .off {
            return "Preview only — editing always stays on the base cage."
        }
        return hasTarget
            ? "Subdivided and reprojected onto the Target. Preview only: never saved or exported."
            : "No Target to reproject onto, so this only densifies the cage without smoothing it."
    }
}

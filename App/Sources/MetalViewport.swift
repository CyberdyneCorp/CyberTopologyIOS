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
/// overlay (two-finger tap undo, three-finger tap redo) sits INSIDE this
/// view's UIKit hierarchy as the topmost subview. Camera recognizers attach
/// to the MTKView itself — an ancestor of the overlay — so every touch is
/// seen by both: taps land on the overlay recognizers, drags/pinches move
/// past the tap slop and are claimed by the camera recognizers. Keeping the
/// overlay a SwiftUI `.overlay` sibling instead would hit-test-shield the
/// MTKView and dead-zone all camera input.
struct MetalViewport: UIViewRepresentable {
    let bundle: DocumentBundle
    var orbitSpeed: Double
    var zoomSpeed: Double
    /// EditMesh overlay display options (task 2.3).
    var overlayOpacity: Double = ViewportSettings.defaultOverlayOpacity
    var xrayEnabled: Bool = false
    var occlusionBias: Double = ViewportSettings.defaultOcclusionBias
    /// DEBUG-only ghost preview (task 2.4 demo path): renders the committed
    /// EditMesh as ghost geometry until the Weave solver (phase 5) exists.
    var ghostDebugEnabled: Bool = false
    /// Viewport resolution scale (task 2.5, spec: "Performance controls").
    var resolutionScale: Double = ViewportSettings.defaultResolutionScale
    let onUndo: @MainActor () -> Void
    let onRedo: @MainActor () -> Void

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
        Coordinator(onUndo: onUndo, onRedo: onRedo)
    }

    func makeUIView(context: Context) -> UIView {
        context.coordinator.makeView()
    }

    func updateUIView(_ view: UIView, context: Context) {
        let coordinator = context.coordinator
        coordinator.undoCoordinator.onUndo = onUndo
        coordinator.undoCoordinator.onRedo = onRedo
        coordinator.renderer?.orbitSpeed = Float(orbitSpeed)
        coordinator.renderer?.zoomSpeed = Float(zoomSpeed)
        coordinator.renderer?.overlaySettings = overlaySettings
        coordinator.applyResolutionScale(resolutionScale)
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
        /// Manifest objects backing the currently loaded GPU mesh; reloads
        /// happen only when this changes (imports, undo/redo of imports).
        private var loadedObjects: [DocumentManifest.Object]?
        /// Identity of the EditMesh currently in the overlay pipeline; the
        /// creation micro-animation replays only when this changes (a newly
        /// imported/created EditMesh), not on every manifest touch.
        private var overlayObjectID: UUID?
        /// Identity of the EditMesh currently rendered as the DEBUG ghost
        /// preview; nil while the preview is off (task 2.4 demo path).
        private var ghostPreviewObjectID: UUID?

        // Retained for tests and for arbitration wiring.
        private(set) var orbitRecognizer: UIPanGestureRecognizer?
        private(set) var pinchRecognizer: UIPinchGestureRecognizer?
        private(set) var twoFingerPanRecognizer: UIPanGestureRecognizer?
        private(set) var doubleTapRecognizer: UITapGestureRecognizer?

        init(onUndo: @escaping @MainActor () -> Void, onRedo: @escaping @MainActor () -> Void) {
            undoCoordinator = UndoGestureView.Coordinator(onUndo: onUndo, onRedo: onRedo)
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

        /// Mounts the two/three-finger tap undo/redo overlay as the topmost
        /// subview (spec: document-model / "Gesture undo/redo").
        private func installUndoOverlay(on view: UIView) {
            let undoOverlay = UndoGestureView.makeConfiguredView(coordinator: undoCoordinator)
            undoOverlay.frame = view.bounds
            undoOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(undoOverlay)
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
            // two/three-finger undo taps need no explicit requirement against
            // pinch/pan because taps complete within the movement slop that
            // pans/pinches need to even begin.
            pinch.delegate = self
            twoFingerPan.delegate = self

            for recognizer in [orbit, pinch, twoFingerPan, doubleTap] {
                view.addGestureRecognizer(recognizer)
            }
            orbitRecognizer = orbit
            pinchRecognizer = pinch
            twoFingerPanRecognizer = twoFingerPan
            doubleTapRecognizer = doubleTap
        }

        /// (Re)loads the render mesh when the document's object list changed.
        func syncMesh(from bundle: DocumentBundle) {
            guard loadedObjects != bundle.manifest.objects else { return }
            loadedObjects = bundle.manifest.objects
            guard let renderer else { return }
            if let object = MetalViewport.renderableObject(in: bundle.manifest),
                let mesh = try? bundle.mesh(for: object) {
                renderer.load(mesh: mesh)
            } else {
                renderer.clearMesh()
            }
            syncOverlay(from: bundle, renderer: renderer)
        }

        /// Loads the first EditMesh into the wireframe overlay pipeline
        /// (task 2.3). The creation animation restarts only for a new
        /// EditMesh object, not for reloads of the same one.
        private func syncOverlay(from bundle: DocumentBundle, renderer: ViewportRenderer) {
            let editMesh = bundle.manifest.objects.first { $0.role == .editMesh }
            guard let editMesh, let mesh = try? bundle.mesh(for: editMesh) else {
                overlayObjectID = nil
                renderer.clearOverlay()
                return
            }
            let isNewObject = editMesh.id != overlayObjectID
            overlayObjectID = editMesh.id
            renderer.loadOverlay(mesh: mesh, restartAnimation: isNewObject)
        }

        /// DEBUG-only demo path for task 2.4: mirrors the first EditMesh
        /// into the ghost pipeline (small normal-offset, pulsing translucent
        /// style) so the ghost render style is visually verifiable before
        /// the Weave solver (phase 5) produces real proposals. Reloads only
        /// when toggled on/off or when the EditMesh object changes.
        func syncGhostPreview(from bundle: DocumentBundle, enabled: Bool) {
            guard let renderer else { return }
            let editMesh = bundle.manifest.objects.first { $0.role == .editMesh }
            guard enabled, let editMesh, let mesh = try? bundle.mesh(for: editMesh) else {
                if ghostPreviewObjectID != nil {
                    ghostPreviewObjectID = nil
                    renderer.clearGhost()
                }
                return
            }
            guard editMesh.id != ghostPreviewObjectID else { return }
            ghostPreviewObjectID = editMesh.id
            renderer.ghostStyle = .debugPreview(sceneRadius: renderer.bounds.radius)
            renderer.loadGhost(mesh: mesh)
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
        }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            trackInteraction(recognizer.state)
            renderer?.zoom(byPinchScale: Float(recognizer.scale))
            recognizer.scale = 1
        }

        @objc func handleTwoFingerPan(_ recognizer: UIPanGestureRecognizer) {
            trackInteraction(recognizer.state)
            let translation = recognizer.translation(in: recognizer.view)
            recognizer.setTranslation(.zero, in: recognizer.view)
            renderer?.pan(byPoints: SIMD2(Float(translation.x), Float(translation.y)))
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
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        let pair = [gestureRecognizer, other]
        return pair.contains { $0 === pinchRecognizer }
            && pair.contains { $0 === twoFingerPanRecognizer }
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

    // Performance controls (task 2.5, spec: "Performance controls"):
    // resolution scale for battery/thermals; MetalFX upscaling engages
    // automatically below 100% where the device supports it.
    static let resolutionScaleKey = "viewportResolutionScale"
    static let defaultResolutionScale = 1.0
    static let resolutionScaleOptions: [Double] = [0.5, 0.75, 1.0]
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
}

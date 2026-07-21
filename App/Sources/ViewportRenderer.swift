import CyberKit
import Metal
import MetalKit
import QuartzCore
import simd

/// Metal renderer for the document viewport (design D2: the shell owns the
/// MTKView/CAMetalLayer and display link; the engine owns geometry and
/// exposes it via the CyberKit render-buffer accessors).
///
/// Task 2.2 structure: target drawing is delegated to a `TargetRenderPath`
/// strategy selected from runtime GPU capabilities. The indexed vertex path
/// is the working pipeline everywhere today and stays the mandatory fallback
/// for the simulator and pre-A14 hardware; the meshlet/LOD path slots in
/// behind the same seam as a follow-up. Geometry lives in a
/// `GeometryBufferPool` (no per-frame allocation; see the pool's memory
/// strategy) and every submitted frame is timed by a `FrameTimeProbe`
/// (os_signpost + GPU timestamps) feeding the device-only perf tests.
@MainActor
final class ViewportRenderer: NSObject {
    /// Pixel formats shared by the MTKView and the offscreen test path.
    static let colorPixelFormat: MTLPixelFormat = .bgra8Unorm_srgb
    static let depthPixelFormat: MTLPixelFormat = .depth32Float
    static let clearColor = MTLClearColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1)
    static let reframeDuration: Double = 0.35

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let depthState: MTLDepthStencilState

    /// Runtime GPU capabilities the render path was selected from.
    let capabilities: RenderPathCapabilities
    /// Geometry pool shared with the render path (exposed for tests
    /// asserting the no-per-frame-reallocation contract).
    let geometryPool: GeometryBufferPool
    /// Active target pipeline strategy.
    private let renderPath: TargetRenderPath
    /// EditMesh wireframe overlay pipeline (task 2.3).
    let overlayPath: EditMeshOverlayPath
    /// Ghost (proposed) geometry pipeline (task 2.4).
    let ghostPath: GhostRenderPath
    /// Render-time probe over every submitted frame (perf harness).
    let frameProbe = FrameTimeProbe()

    var activeRenderPathKind: TargetRenderPathKind { renderPath.kind }

    /// Current camera pose. Settable so tests can drive rescue scenarios.
    var camera = CameraState()
    private(set) var bounds = SceneBounds.unit
    private(set) var viewportSize = CGSize(width: 1, height: 1)
    private var animation: CameraAnimation?
    /// The frame-to-fit pose set by the last geometry load. While the camera
    /// still sits exactly on it (nothing moved it since), a viewport-size
    /// change re-fits the framing: meshes typically load during the first
    /// SwiftUI update pass, before the MTKView's first layout, so the
    /// initial fit is computed against the placeholder 1×1 viewport
    /// (aspect 1) and would otherwise clip a wide mesh on portrait screens.
    /// Any camera interaction breaks the equality and ends the re-fitting.
    private var initialFraming: CameraState?

    var hasMesh: Bool { renderPath.hasGeometry }
    var hasOverlay: Bool { overlayPath.hasGeometry }
    var hasGhost: Bool { ghostPath.hasGeometry }

    /// EditMesh overlay display state (opacity / x-ray / occlusion bias),
    /// pushed from the view-options popover.
    var overlaySettings = OverlaySettings() {
        didSet { if overlaySettings != oldValue { invalidate() } }
    }
    /// Start time of the overlay creation micro-animation; nil renders the
    /// wireframe fully revealed.
    private(set) var overlayCreationTime: Double?

    /// Ghost (proposed) geometry style; the pulse is driven by the frame
    /// time uniform, so mutating this never touches geometry.
    var ghostStyle = GhostStyle.proposal {
        didSet { if ghostStyle != oldValue { invalidate() } }
    }
    /// Retains the engine mesh whose buffers the ghost path wrapped with
    /// `bytesNoCopy` (zero-copy lifetime contract: the aliasing MTLBuffers
    /// must not outlive the Mesh — see `EngineBufferSharing`). nil when the
    /// ghost took the pooled-copy path or is empty.
    private(set) var ghostSourceMesh: Mesh?

    /// User settings (persisted app-side): orbit/zoom sensitivity.
    var orbitSpeed: Float = 1
    var zoomSpeed: Float = 1

    // MARK: - Frame pacing + performance controls (task 2.5)

    /// Render-on-demand hook: fired whenever renderer state changed in a
    /// way that requires a new frame (the pacer marks the paused MTKView
    /// dirty). nil in offscreen/test use.
    var onNeedsDisplay: (@MainActor () -> Void)?

    /// View points → drawable pixels factor (the MTKView's
    /// `contentScaleFactor`). Keeps gesture math in view points regardless
    /// of the drawable's resolution scale (spec: enabling performance
    /// controls SHALL NOT affect gesture behavior).
    var contentScale: Float = 1

    /// Viewport resolution scale (0.5 / 0.75 / 1.0, persisted app-side).
    /// The drawable/render-target scaling itself is applied by the view
    /// host (plain path) or the MetalFX stage (upscaled path).
    var resolutionScale: Double = ViewportSettings.defaultResolutionScale {
        didSet { if resolutionScale != oldValue { invalidate() } }
    }

    /// The upscaler the current device/scale combination selects (pure
    /// decision; MetalFX only where supported and scale < 100%).
    var activeUpscalerKind: ViewportUpscalerKind {
        UpscalerSelection.availableKind(for: capabilities, resolutionScale: resolutionScale)
    }

    /// MetalFX stage (unprepared stub wherever MetalFX is unavailable).
    let upscalerStage = SpatialUpscalerStage()

    /// Requests one new frame from the pacing layer.
    func invalidate() {
        onNeedsDisplay?()
    }

    /// True while any time-driven animation needs continuous redraws:
    /// camera reframe, overlay creation sweep, or the ghost pulse (ghosts
    /// animate for as long as they are shown).
    func isAnimating(at time: Double = CACurrentMediaTime()) -> Bool {
        animation != nil || isOverlayAnimating(at: time) || hasGhost
    }

    private var aspect: Float {
        Float(viewportSize.width / max(viewportSize.height, 1))
    }

    /// Fails only when Metal is unavailable or the selected render path
    /// cannot build its pipeline (programmer error, surfaced loudly by
    /// tests). `preferPrivateGeometryStorage` defaults to the capability
    /// detection (private storage only pays off without unified memory);
    /// tests override it to exercise the staging-blit path on simulator.
    init?(
        device: MTLDevice? = MTLCreateSystemDefaultDevice(),
        preferPrivateGeometryStorage: Bool? = nil
    ) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        let capabilities = RenderPathCapabilities(device: device)
        let pool = GeometryBufferPool(
            device: device,
            commandQueue: queue,
            preferPrivateStorage: preferPrivateGeometryStorage ?? !capabilities.hasUnifiedMemory
        )

        // Capability-gated pipeline split (task 2.2): today every kind
        // resolves to the indexed vertex path; the meshlet strategy will
        // add its own case here without touching the rest of the renderer.
        let path: TargetRenderPath?
        switch TargetRenderPathSelection.availableKind(for: capabilities) {
        case .indexedVertex, .meshlet:
            path = IndexedVertexRenderPath(device: device, bufferPool: pool)
        }

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .lessEqual
        depthDescriptor.isDepthWriteEnabled = true

        let overlay = EditMeshOverlayPath(
            device: device, commandQueue: queue,
            preferPrivateStorage: pool.usesPrivateStorage
        )
        let ghost = GhostRenderPath(
            device: device, commandQueue: queue,
            preferPrivateStorage: pool.usesPrivateStorage
        )

        guard
            let path, let overlay, let ghost,
            let depth = device.makeDepthStencilState(descriptor: depthDescriptor)
        else { return nil }

        self.device = device
        self.commandQueue = queue
        self.capabilities = capabilities
        self.geometryPool = pool
        self.renderPath = path
        self.overlayPath = overlay
        self.ghostPath = ghost
        self.depthState = depth
        super.init()
    }

    // MARK: - Mesh loading

    /// Uploads the mesh's render data (engine-triangulated indices, engine
    /// -computed normals/colors) into pooled GPU buffers and reframes the
    /// camera. Meshes without vertex colors render in neutral gray.
    /// Zero-copy note: the Target keeps the pooled upload (it must also
    /// serve the private-storage fallback); the ghost path (task 2.4)
    /// shares engine buffers via `EngineBufferSharing` when they qualify.
    func load(mesh: Mesh) {
        mesh.withRenderBuffers { buffers in
            loadGeometry(
                TargetGeometry(
                    positions: buffers.positions,
                    normals: buffers.normals,
                    colors: buffers.colors,
                    indices: buffers.triangleIndices
                )
            )
        }
    }

    /// Array-based entry used by the perf harness (replicated procedural
    /// buffers) and unit tests. Production mesh loads go through
    /// `load(mesh:)`; this performs no mesh algorithms — it only uploads.
    func loadGeometry(
        positions: [Float], normals: [Float], colors: [Float]?, indices: [UInt32]
    ) {
        positions.withUnsafeBufferPointer { positionsPtr in
            normals.withUnsafeBufferPointer { normalsPtr in
                indices.withUnsafeBufferPointer { indicesPtr in
                    withOptionalBufferPointer(colors) { colorsPtr in
                        loadGeometry(
                            TargetGeometry(
                                positions: positionsPtr,
                                normals: normalsPtr,
                                colors: colorsPtr,
                                indices: indicesPtr
                            )
                        )
                    }
                }
            }
        }
    }

    private func withOptionalBufferPointer(
        _ array: [Float]?, _ body: (UnsafeBufferPointer<Float>?) -> Void
    ) {
        if let array {
            array.withUnsafeBufferPointer { body($0) }
        } else {
            body(nil)
        }
    }

    private func loadGeometry(_ geometry: TargetGeometry) {
        guard
            let sceneBounds = SceneBounds(positions: geometry.positions),
            renderPath.load(geometry)
        else {
            clearMesh()
            return
        }
        bounds = sceneBounds
        camera = CameraState.framing(bounds, aspect: aspect)
        initialFraming = camera
        animation = nil
        invalidate()
    }

    /// Drops all geometry (empty document); the viewport clears to
    /// background. Pool allocations are kept for the next load.
    func clearMesh() {
        renderPath.clear()
        bounds = .unit
        camera = CameraState.framing(bounds, aspect: aspect)
        initialFraming = camera
        animation = nil
        invalidate()
    }

    // MARK: - EditMesh overlay (task 2.3)

    /// Uploads an EditMesh's wireframe (engine-compacted positions + unique
    /// face-edge indices) into the overlay pipeline. `restartAnimation`
    /// plays the creation micro-animation from `time` — pass true for a
    /// newly imported/created EditMesh, false for reloads of the same one.
    func loadOverlay(
        mesh: Mesh, restartAnimation: Bool = true, at time: Double = CACurrentMediaTime()
    ) {
        let loaded = mesh.withRenderBuffers { buffers in
            overlayPath.load(positions: buffers.positions, edges: buffers.edgeIndices)
        }
        guard loaded else {
            overlayCreationTime = nil
            invalidate()
            return
        }
        if restartAnimation {
            overlayCreationTime = time
        }
        invalidate()
    }

    /// Array-based overlay entry for unit tests and offscreen render tests
    /// (no engine handle needed; upload only, no mesh algorithms).
    func loadOverlayGeometry(
        positions: [Float], edges: [UInt32],
        restartAnimation: Bool = true, at time: Double = CACurrentMediaTime()
    ) {
        positions.withUnsafeBufferPointer { positionsPtr in
            edges.withUnsafeBufferPointer { edgesPtr in
                guard overlayPath.load(positions: positionsPtr, edges: edgesPtr) else {
                    overlayCreationTime = nil
                    return
                }
                if restartAnimation {
                    overlayCreationTime = time
                }
            }
        }
        invalidate()
    }

    func clearOverlay() {
        overlayPath.clear()
        overlayCreationTime = nil
        invalidate()
    }

    /// True while the creation micro-animation still has frames to show.
    func isOverlayAnimating(at time: Double = CACurrentMediaTime()) -> Bool {
        hasOverlay
            && OverlayAnimation.progress(creationTime: overlayCreationTime, now: time) < 1
    }

    // MARK: - Ghost geometry (task 2.4)

    /// Loads a proposed ("ghost") mesh — a Weave result, auto-seam proposal
    /// or autocomplete patch — for translucent pulsing display alongside the
    /// committed EditMesh wireframe.
    ///
    /// Buffer sharing: the engine buffers go zero-copy (`bytesNoCopy`) when
    /// the engine's caches honor the VM-allocation contract AND they are
    /// page-aligned/page-padded on unified memory, else through one memcpy
    /// into the ghost pool; see `EngineBufferSharing`. Today the caches are
    /// malloc-backed (`engineRenderCachesAreVMAllocated == false`), so
    /// zero-copy is disallowed outright — a coincidentally page-aligned
    /// malloc buffer must never reach `makeBuffer(bytesNoCopy:)`, which
    /// requires `vm_allocate`/`mmap` memory. On the (future) zero-copy path
    /// the renderer retains `mesh` in `ghostSourceMesh` so the aliasing
    /// MTLBuffers never outlive it; `ghostPath.load` drains the queue before
    /// dropping previous wrappers, so replacing/releasing the old source
    /// mesh below is ordered after every in-flight frame.
    func loadGhost(mesh: Mesh) {
        let loaded = mesh.withRenderBuffers { buffers in
            ghostPath.load(
                positions: buffers.positions,
                normals: buffers.normals,
                indices: buffers.triangleIndices,
                hasUnifiedMemory: capabilities.hasUnifiedMemory,
                // Lifetime is held via ghostSourceMesh below, but the
                // allocator contract must ALSO hold (see the flag's docs).
                allowZeroCopy: EngineBufferSharing.engineRenderCachesAreVMAllocated
            )
        }
        ghostSourceMesh = (loaded && ghostPath.activeSharing == .zeroCopy) ? mesh : nil
        invalidate()
    }

    /// Array-based ghost entry for unit tests and offscreen render tests.
    /// Always copies: the arrays are transient, so zero-copy wrapping would
    /// dangle (see `GhostRenderPath.load(allowZeroCopy:)`).
    func loadGhostGeometry(positions: [Float], normals: [Float], indices: [UInt32]) {
        positions.withUnsafeBufferPointer { positionsPtr in
            normals.withUnsafeBufferPointer { normalsPtr in
                indices.withUnsafeBufferPointer { indicesPtr in
                    ghostPath.load(
                        positions: positionsPtr, normals: normalsPtr,
                        indices: indicesPtr,
                        hasUnifiedMemory: capabilities.hasUnifiedMemory,
                        allowZeroCopy: false
                    )
                }
            }
        }
        // Release the previous zero-copy source mesh only AFTER the load
        // above: `ghostPath.load` drains the queue before dropping any live
        // zero-copy wrappers, so freeing the engine memory they alias here
        // cannot race an in-flight frame (same drain-then-release ordering
        // as `clearGhost`; nil-ing first would deallocate pages a committed
        // frame may still be reading).
        ghostSourceMesh = nil
        invalidate()
    }

    func clearGhost() {
        // clear() drains the command queue before dropping any zero-copy
        // wrappers, so releasing the source mesh (freeing the engine memory
        // those wrappers alias) afterwards cannot race an in-flight frame.
        ghostPath.clear()
        ghostSourceMesh = nil
        invalidate()
    }

    // MARK: - Camera interaction

    func orbit(byPoints delta: SIMD2<Float>) {
        animation = nil
        camera.orbit(byPoints: delta, speed: orbitSpeed)
        invalidate()
    }

    func zoom(byPinchScale scale: Float) {
        animation = nil
        camera.zoom(byPinchScale: scale, speed: zoomSpeed, in: bounds)
        invalidate()
    }

    /// `delta` is in view points. The viewport height is converted from
    /// drawable pixels back to points via `contentScale`, so pan tracking
    /// is 1:1 with the fingers at any resolution scale (spec scenario
    /// "Resolution downscale": gestures behave identically).
    func pan(byPoints delta: SIMD2<Float>) {
        animation = nil
        let heightPoints = Float(max(viewportSize.height, 1)) / max(contentScale, 1e-3)
        camera.pan(byPoints: delta, viewportHeight: heightPoints)
        invalidate()
    }

    /// Camera rescue / double-tap reframe: always reaches a valid framing
    /// (spec: "Camera rescue from inside the mesh"), animated over one short
    /// transition when requested.
    func reframe(animated: Bool, at time: Double = CACurrentMediaTime()) {
        let target = camera.reframed(to: bounds, aspect: aspect)
        if animated {
            animation = CameraAnimation(
                from: camera, to: target, startTime: time, duration: Self.reframeDuration
            )
        } else {
            animation = nil
            camera = target
        }
        invalidate()
    }

    func setViewportSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        guard size != viewportSize else { return }
        viewportSize = size
        refitInitialFramingIfUntouched()
        invalidate()
    }

    /// Recomputes the frame-to-fit pose for the current aspect when the
    /// camera is still exactly the framing set by the last load (see
    /// `initialFraming`); user-moved cameras are never touched.
    private func refitInitialFramingIfUntouched() {
        guard let initialFraming, camera == initialFraming else { return }
        camera = CameraState.framing(bounds, aspect: aspect)
        self.initialFraming = camera
    }

    /// Advances the reframe animation; returns true while animating.
    @discardableResult
    func stepAnimation(at time: Double = CACurrentMediaTime()) -> Bool {
        guard let animation else { return false }
        let (pose, finished) = animation.value(at: time)
        camera = pose
        if finished { self.animation = nil }
        return !finished
    }

    // MARK: - Drawing

    /// Encodes one frame into `descriptor`. Shared by the on-screen MTKView
    /// path and the offscreen test path. Never allocates GPU memory: the
    /// render paths bind pooled buffers only. `time` drives the overlay
    /// creation animation (injectable so tests render deterministic frames).
    func encodeFrame(
        into descriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer,
        at time: Double = CACurrentMediaTime()
    ) {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }
        defer { encoder.endEncoding() }
        guard hasMesh || hasOverlay || hasGhost else { return }

        let view = camera.viewMatrix()
        let projection = camera.projectionMatrix(aspect: aspect, bounds: bounds)
        let mvp = projection * view
        // Headlight: the directional light travels along the view direction
        // so geometry is always lit regardless of orbit angle; the ambient
        // floor lives in the fragment shader.
        let forward = camera.basis.forward
        let uniforms = ViewportUniforms(
            mvp: mvp,
            lightDirection: SIMD4(forward.x, forward.y, forward.z, 0)
        )

        encoder.setDepthStencilState(depthState)
        // Both winding orders stay visible in the fallback pipeline: imports
        // with flipped faces must not vanish into a "blank viewport".
        encoder.setCullMode(.none)
        renderPath.encode(into: encoder, uniforms: uniforms)

        // Ghost proposals render between the Target (whose depth they test
        // against) and the committed wireframe, so accepted topology always
        // reads on top of proposals. The pulse is a pure function of `time`.
        ghostPath.encode(
            into: encoder,
            uniforms: GhostUniformsFactory.uniforms(
                mvp: mvp, viewDirection: forward, style: ghostStyle, time: time
            )
        )

        // EditMesh wireframe renders after the Target so its depth-tested
        // and x-ray passes see the full Target depth buffer.
        overlayPath.encode(
            into: encoder,
            mvp: mvp,
            settings: overlaySettings,
            animationProgress: OverlayAnimation.progress(
                creationTime: overlayCreationTime, now: time
            )
        )
    }

    /// Offscreen render + readback for tests and the renderer smoke check:
    /// returns BGRA8 rows (bytesPerRow = 4 × width). Renders into a private
    /// texture and blits into a shared buffer because simulator Metal
    /// requires private render targets.
    func renderOffscreen(
        width: Int, height: Int, at time: Double = CACurrentMediaTime()
    ) -> [UInt8]? {
        setViewportSize(CGSize(width: width, height: height))

        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.colorPixelFormat, width: width, height: height, mipmapped: false
        )
        colorDescriptor.usage = [.renderTarget]
        colorDescriptor.storageMode = .private
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.depthPixelFormat, width: width, height: height, mipmapped: false
        )
        depthDescriptor.usage = [.renderTarget]
        depthDescriptor.storageMode = .private

        let bytesPerRow = width * 4
        guard
            let colorTexture = device.makeTexture(descriptor: colorDescriptor),
            let depthTexture = device.makeTexture(descriptor: depthDescriptor),
            let readback = device.makeBuffer(length: bytesPerRow * height),
            let commandBuffer = commandQueue.makeCommandBuffer()
        else { return nil }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = colorTexture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = Self.clearColor
        pass.depthAttachment.texture = depthTexture
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1

        encodeFrame(into: pass, commandBuffer: commandBuffer, at: time)

        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        blit.copy(
            from: colorTexture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: readback, destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bytesPerRow * height
        )
        blit.endEncoding()
        frameProbe.attach(to: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let pointer = readback.contents().bindMemory(
            to: UInt8.self, capacity: bytesPerRow * height
        )
        return Array(UnsafeBufferPointer(start: pointer, count: bytesPerRow * height))
    }
}

// MTKView drives the display link and calls the delegate on the main thread;
// the conformance methods are nonisolated per protocol and hop back onto the
// main actor explicitly.
extension ViewportRenderer: MTKViewDelegate {
    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        MainActor.assumeIsolated {
            setViewportSize(size)
        }
    }

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated {
            stepAnimation()
            guard
                let drawable = view.currentDrawable,
                let commandBuffer = commandQueue.makeCommandBuffer()
            else { return }
            // MetalFX path first (task 2.5): render small, upscale to the
            // full-resolution drawable. Any unavailability (simulator,
            // unsupported device, allocation failure) falls back to the
            // plain path against the view's own pass descriptor.
            if !encodeUpscaledFrame(to: drawable.texture, commandBuffer: commandBuffer) {
                guard let descriptor = view.currentRenderPassDescriptor else { return }
                encodeFrame(into: descriptor, commandBuffer: commandBuffer)
            }
            frameProbe.attach(to: commandBuffer)
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}

extension ViewportRenderer {
    /// Encodes scene → MetalFX spatial upscale → blit into `drawableTexture`.
    /// Returns false (encoding nothing) whenever the upscaler is not
    /// selected or cannot be prepared — the caller then takes the plain
    /// path. Requires the drawable to be blit-capable
    /// (`framebufferOnly = false`, arranged by the view host on
    /// MetalFX-capable devices only).
    func encodeUpscaledFrame(
        to drawableTexture: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        at time: Double = CACurrentMediaTime()
    ) -> Bool {
        guard activeUpscalerKind == .metalFXSpatial else { return false }
        let drawableSize = CGSize(
            width: drawableTexture.width, height: drawableTexture.height
        )
        let renderSize = ResolutionScalePolicy.renderSize(
            drawableSize: drawableSize,
            resolutionScale: resolutionScale,
            upscaler: .metalFXSpatial
        )
        guard
            renderSize != drawableSize,
            upscalerStage.prepare(
                device: device,
                renderSize: renderSize,
                outputSize: drawableSize,
                colorFormat: Self.colorPixelFormat,
                depthFormat: Self.depthPixelFormat
            ),
            let scenePass = upscalerStage.scenePassDescriptor(clearColor: Self.clearColor),
            let output = upscalerStage.output
        else { return false }

        encodeFrame(into: scenePass, commandBuffer: commandBuffer, at: time)
        guard
            upscalerStage.encodeUpscale(into: commandBuffer),
            let blit = commandBuffer.makeBlitCommandEncoder()
        else { return false }
        blit.copy(from: output, to: drawableTexture)
        blit.endEncoding()
        return true
    }
}

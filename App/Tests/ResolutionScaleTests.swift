import CoreGraphics
import Metal
import Testing
import simd
@testable import CyberTopology

/// Resolution scale + MetalFX selection (task 2.5, spec: viewport-rendering
/// / "Performance controls", scenario "Resolution downscale"): drawable-size
/// math, capability-gated upscaler selection, and gesture independence from
/// the drawable scale.
struct ResolutionScalePolicyTests {
    @Test func fiftyPercentQuartersDrawablePixels() {
        // 2x iPad screen, 400×300 pt viewport.
        let full = ResolutionScalePolicy.drawableSize(
            viewPointSize: CGSize(width: 400, height: 300), screenScale: 2,
            resolutionScale: 1.0, upscaler: .none
        )
        let half = ResolutionScalePolicy.drawableSize(
            viewPointSize: CGSize(width: 400, height: 300), screenScale: 2,
            resolutionScale: 0.5, upscaler: .none
        )
        #expect(full == CGSize(width: 800, height: 600))
        #expect(half == CGSize(width: 400, height: 300))
        // Rendering cost (pixels shaded) drops with scale²: 50% → 25%.
        let fullPixels = full.width * full.height
        let halfPixels = half.width * half.height
        #expect(halfPixels == fullPixels / 4)
    }

    @Test func seventyFivePercentScalesContentScaleFactor() {
        #expect(
            ResolutionScalePolicy.contentScaleFactor(
                screenScale: 2, resolutionScale: 0.75, upscaler: .none
            ) == 1.5
        )
        #expect(
            ResolutionScalePolicy.contentScaleFactor(
                screenScale: 2, resolutionScale: 1.0, upscaler: .none
            ) == 2
        )
    }

    @Test func scaleIsClampedAgainstBogusPersistedValues() {
        #expect(ResolutionScalePolicy.clamped(0) == ResolutionScalePolicy.minimumScale)
        #expect(ResolutionScalePolicy.clamped(-3) == ResolutionScalePolicy.minimumScale)
        #expect(ResolutionScalePolicy.clamped(7) == ResolutionScalePolicy.maximumScale)
        #expect(ResolutionScalePolicy.clamped(0.75) == 0.75)
    }

    @Test func drawableSizeNeverCollapsesToZero() {
        let tiny = ResolutionScalePolicy.drawableSize(
            viewPointSize: CGSize(width: 1, height: 1), screenScale: 1,
            resolutionScale: 0.25, upscaler: .none
        )
        #expect(tiny.width >= 1 && tiny.height >= 1)
    }

    /// MetalFX mode: the drawable stays at native resolution (the scaler
    /// outputs native pixels); the scene render target shrinks instead.
    @Test func metalFXKeepsDrawableNativeAndShrinksRenderTarget() {
        #expect(
            ResolutionScalePolicy.contentScaleFactor(
                screenScale: 2, resolutionScale: 0.5, upscaler: .metalFXSpatial
            ) == 2
        )
        let renderSize = ResolutionScalePolicy.renderSize(
            drawableSize: CGSize(width: 800, height: 600),
            resolutionScale: 0.5, upscaler: .metalFXSpatial
        )
        #expect(renderSize == CGSize(width: 400, height: 300))
        // Plain path renders 1:1 into the (already scaled) drawable.
        #expect(
            ResolutionScalePolicy.renderSize(
                drawableSize: CGSize(width: 400, height: 300),
                resolutionScale: 0.5, upscaler: .none
            ) == CGSize(width: 400, height: 300)
        )
    }
}

struct UpscalerSelectionTests {
    private func capabilities(metalFX: Bool) -> RenderPathCapabilities {
        RenderPathCapabilities(
            supportsMeshShaders: false, hasUnifiedMemory: true,
            supportsMetalFXSpatial: metalFX
        )
    }

    @Test func metalFXSelectedOnlyWhenSupportedAndDownscaled() {
        #expect(
            UpscalerSelection.availableKind(
                for: capabilities(metalFX: true), resolutionScale: 0.5
            ) == .metalFXSpatial
        )
        #expect(
            UpscalerSelection.availableKind(
                for: capabilities(metalFX: true), resolutionScale: 0.75
            ) == .metalFXSpatial
        )
    }

    @Test func fullResolutionNeverUpscales() {
        #expect(
            UpscalerSelection.availableKind(
                for: capabilities(metalFX: true), resolutionScale: 1.0
            ) == .none
        )
    }

    /// Simulator/pre-MetalFX hardware: plain scaled render, never a crash.
    @Test func unsupportedDeviceFallsBackToPlainScaledRender() {
        for scale in ViewportSettings.resolutionScaleOptions {
            #expect(
                UpscalerSelection.availableKind(
                    for: capabilities(metalFX: false), resolutionScale: scale
                ) == .none
            )
        }
    }

    /// The runtime capability and the selection must agree with the real
    /// device (on the simulator MetalFX is absent, so this exercises the
    /// fallback decision end-to-end).
    @MainActor
    @Test func detectionAndSelectionAgreeOnThisDevice() throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "Metal unavailable")
        let capabilities = RenderPathCapabilities(device: device)
        let supported = MetalFXCapability.spatialScalingSupported(device: device)
        #expect(capabilities.supportsMetalFXSpatial == supported)
        #expect(
            UpscalerSelection.availableKind(for: capabilities, resolutionScale: 0.5)
                == (supported ? .metalFXSpatial : .none)
        )
        #if targetEnvironment(simulator)
            // The MetalFX framework does not exist in the simulator SDK.
            #expect(!supported)
        #endif
    }
}

@MainActor
struct ResolutionScaleRendererTests {
    private func makeRenderer() throws -> ViewportRenderer {
        try #require(ViewportRenderer(), "Metal device unavailable")
    }

    private func loadTriangle(into renderer: ViewportRenderer) {
        renderer.loadGeometry(
            positions: [0, 0, 0, 1, 0, 0, 0, 1, 0],
            normals: [0, 0, 1, 0, 0, 1, 0, 0, 1],
            colors: nil,
            indices: [0, 1, 2]
        )
    }

    /// Spec scenario "Resolution downscale": gestures operate in view
    /// points and behave identically at any drawable scale. The same
    /// point-space gesture sequence must produce the same camera pose when
    /// the drawable is 100% (contentScale 2) and 50% (contentScale 1) of a
    /// 2x screen.
    @Test func gesturesInViewPointsAreIndependentOfDrawableScale() throws {
        let fullRes = try makeRenderer()
        loadTriangle(into: fullRes)
        fullRes.contentScale = 2  // 100% on a 2x screen
        fullRes.setViewportSize(CGSize(width: 800, height: 600))  // pixels

        let halfRes = try makeRenderer()
        loadTriangle(into: halfRes)
        halfRes.contentScale = 1  // 50% on a 2x screen
        halfRes.setViewportSize(CGSize(width: 400, height: 300))  // pixels

        for renderer in [fullRes, halfRes] {
            renderer.orbit(byPoints: SIMD2(25, -10))
            renderer.zoom(byPinchScale: 1.5)
            renderer.pan(byPoints: SIMD2(40, 12))
        }

        #expect(fullRes.camera.azimuth == halfRes.camera.azimuth)
        #expect(fullRes.camera.elevation == halfRes.camera.elevation)
        #expect(fullRes.camera.distance == halfRes.camera.distance)
        let focusDelta = fullRes.camera.focus - halfRes.camera.focus
        #expect(length(focusDelta) < 1e-5)
    }

    /// On the simulator the upscaler stage must degrade gracefully: never
    /// prepared, plain path taken, no crash (spec: MetalFX "where
    /// available").
    @Test func upscalerStagePreparesOnlyWhereSupported() throws {
        let renderer = try makeRenderer()
        let prepared = renderer.upscalerStage.prepare(
            device: renderer.device,
            renderSize: CGSize(width: 64, height: 64),
            outputSize: CGSize(width: 128, height: 128),
            colorFormat: ViewportRenderer.colorPixelFormat,
            depthFormat: ViewportRenderer.depthPixelFormat
        )
        #expect(prepared == renderer.capabilities.supportsMetalFXSpatial)
        #expect(renderer.upscalerStage.isPrepared == prepared)
        if !prepared {
            #expect(renderer.upscalerStage.scenePassDescriptor(
                clearColor: ViewportRenderer.clearColor) == nil)
        }
        renderer.upscalerStage.invalidate()
        #expect(!renderer.upscalerStage.isPrepared)
    }

    @Test func upscalerStageRejectsDegenerateSizes() throws {
        let renderer = try makeRenderer()
        #expect(
            !renderer.upscalerStage.prepare(
                device: renderer.device,
                renderSize: .zero,
                outputSize: CGSize(width: 128, height: 128),
                colorFormat: ViewportRenderer.colorPixelFormat,
                depthFormat: ViewportRenderer.depthPixelFormat
            )
        )
        // Output smaller than input is upside-down usage: refused.
        #expect(
            !renderer.upscalerStage.prepare(
                device: renderer.device,
                renderSize: CGSize(width: 128, height: 128),
                outputSize: CGSize(width: 64, height: 64),
                colorFormat: ViewportRenderer.colorPixelFormat,
                depthFormat: ViewportRenderer.depthPixelFormat
            )
        )
    }

    /// The renderer's draw-path guard: where MetalFX is unavailable the
    /// upscaled encode refuses and the caller falls back to the plain path
    /// (the path every simulator frame, screenshot and offscreen test
    /// actually exercises).
    @Test func encodeUpscaledFrameFallsBackWhereUnsupported() throws {
        let renderer = try makeRenderer()
        renderer.resolutionScale = 0.5
        loadTriangle(into: renderer)
        guard renderer.capabilities.supportsMetalFXSpatial else {
            #expect(renderer.activeUpscalerKind == .none)
            // Offscreen render at a scaled size still works (plain path).
            let frame = renderer.renderOffscreen(width: 64, height: 48)
            #expect(frame != nil)
            return
        }
        // MetalFX-capable device: selection engages below 100%.
        #expect(renderer.activeUpscalerKind == .metalFXSpatial)
    }

    @Test func settingsExposeExactlyTheSpecScaleOptions() {
        #expect(ViewportSettings.resolutionScaleOptions == [0.5, 0.75, 1.0])
        #expect(
            ViewportSettings.resolutionScaleOptions
                .contains(ViewportSettings.defaultResolutionScale)
        )
    }
}

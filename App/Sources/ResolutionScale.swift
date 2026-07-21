import CoreGraphics

// Resolution scale + upscaler selection (task 2.5, spec: viewport-rendering
// / "Performance controls"). Pure math and pure capability decisions —
// unit-tested without Metal, mirroring `TargetRenderPathSelection`.

/// Which upscaling stage sits between the scene render and the drawable.
enum ViewportUpscalerKind: String, CaseIterable, Sendable {
    /// Plain scaled render: the drawable itself is smaller (contents
    /// stretched by Core Animation). Works everywhere; the simulator and
    /// non-MetalFX hardware always take this path.
    case none
    /// MetalFX spatial upscaler: scene renders small into an intermediate
    /// texture and is upscaled to a full-resolution drawable.
    case metalFXSpatial
}

/// Capability-gated upscaler selection (runtime
/// `MTLFXSpatialScaler.supportsDevice` feeds
/// `RenderPathCapabilities.supportsMetalFXSpatial`).
enum UpscalerSelection {
    /// MetalFX engages only when there is something to upscale (scale < 1)
    /// and the device supports it; everything else falls back to the plain
    /// scaled render — never a crash on unsupported hardware.
    static func availableKind(
        for capabilities: RenderPathCapabilities, resolutionScale: Double
    ) -> ViewportUpscalerKind {
        guard
            capabilities.supportsMetalFXSpatial,
            ResolutionScalePolicy.clamped(resolutionScale) < 1
        else { return .none }
        return .metalFXSpatial
    }
}

/// Drawable-size math for the resolution scale option. The scale applies to
/// the Metal drawable only — UIKit/SwiftUI chrome stays at native screen
/// scale and remains sharp.
enum ResolutionScalePolicy {
    /// Floor keeps the drawable usable (and division-safe) even for bogus
    /// persisted values.
    static let minimumScale = 0.25
    static let maximumScale = 1.0

    static func clamped(_ scale: Double) -> Double {
        min(max(scale, minimumScale), maximumScale)
    }

    /// The `contentScaleFactor` the MTKView should use (its drawable is
    /// `bounds × contentScaleFactor` in pixels):
    ///
    ///  * plain path — the drawable itself shrinks with the scale;
    ///  * MetalFX path — the drawable stays full-resolution (the scaler
    ///    outputs native pixels); the *render* target shrinks instead
    ///    (`renderSize`).
    static func contentScaleFactor(
        screenScale: CGFloat, resolutionScale: Double, upscaler: ViewportUpscalerKind
    ) -> CGFloat {
        switch upscaler {
        case .none:
            return screenScale * CGFloat(clamped(resolutionScale))
        case .metalFXSpatial:
            return screenScale
        }
    }

    /// Size in pixels of the texture the scene actually renders into for a
    /// drawable of `drawableSize` pixels.
    static func renderSize(
        drawableSize: CGSize, resolutionScale: Double, upscaler: ViewportUpscalerKind
    ) -> CGSize {
        switch upscaler {
        case .none:
            // The drawable is already scaled; render 1:1 into it.
            return drawableSize
        case .metalFXSpatial:
            let scale = CGFloat(clamped(resolutionScale))
            return CGSize(
                width: max((drawableSize.width * scale).rounded(), 1),
                height: max((drawableSize.height * scale).rounded(), 1)
            )
        }
    }

    /// Full drawable-size pipeline for a view of `viewPointSize` points on
    /// a `screenScale` screen — the quantity the "rendering cost SHALL drop
    /// accordingly" scenario is asserted on (pixel count scales with
    /// scale²).
    static func drawableSize(
        viewPointSize: CGSize, screenScale: CGFloat,
        resolutionScale: Double, upscaler: ViewportUpscalerKind
    ) -> CGSize {
        let factor = contentScaleFactor(
            screenScale: screenScale, resolutionScale: resolutionScale, upscaler: upscaler
        )
        return CGSize(
            width: max((viewPointSize.width * factor).rounded(), 1),
            height: max((viewPointSize.height * factor).rounded(), 1)
        )
    }
}

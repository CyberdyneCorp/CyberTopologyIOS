import Metal
import QuartzCore

#if canImport(MetalFX)
    import MetalFX
#endif

// MetalFX spatial upscaling (task 2.5, spec: viewport-rendering /
// "Performance controls" — "MetalFX upscaling where available").
//
// The MetalFX framework does not exist in the simulator SDK at all
// (`canImport(MetalFX)` is false there), and `supportsDevice` gates older
// hardware, so every entry point here degrades to "unsupported" instead of
// crashing; the renderer then takes the plain scaled-drawable path, which is
// exactly what simulator tests exercise. The upscaler selection itself is a
// pure function (`UpscalerSelection.availableKind`).

/// Runtime MetalFX capability check, isolated so the rest of the app never
/// touches the framework directly.
enum MetalFXCapability {
    /// True when `MTLFXSpatialScaler` can run on this device (always false
    /// on the simulator: the framework is absent from its SDK).
    static func spatialScalingSupported(device: MTLDevice) -> Bool {
        #if canImport(MetalFX)
            return MTLFXSpatialScalerDescriptor.supportsDevice(device)
        #else
            return false
        #endif
    }
}

/// Owns the MTLFXSpatialScaler plus its input/output textures, rebuilt only
/// when the render/output sizes change (never per frame). On platforms
/// without MetalFX this compiles to a permanent "not prepared" stub — the
/// renderer's fallback guard (`prepare` returning false) is the same code
/// path either way.
@MainActor
final class SpatialUpscalerStage {
    /// Scaled scene color target (also the scaler input).
    private(set) var inputColor: MTLTexture?
    /// Scaled scene depth target.
    private(set) var inputDepth: MTLTexture?
    /// Full-resolution scaler output, blitted to the drawable.
    private(set) var output: MTLTexture?

    #if canImport(MetalFX)
        private var scaler: MTLFXSpatialScaler?
    #endif

    private var preparedInputSize = CGSize.zero
    private var preparedOutputSize = CGSize.zero

    /// (Re)builds the scaler and textures for the given sizes. Returns
    /// false — leaving the stage unprepared — whenever MetalFX is
    /// unavailable, sizes are degenerate, or any allocation fails; the
    /// caller must fall back to the plain render path.
    func prepare(
        device: MTLDevice,
        renderSize: CGSize,
        outputSize: CGSize,
        colorFormat: MTLPixelFormat,
        depthFormat: MTLPixelFormat
    ) -> Bool {
        guard
            MetalFXCapability.spatialScalingSupported(device: device),
            renderSize.width >= 1, renderSize.height >= 1,
            outputSize.width >= renderSize.width,
            outputSize.height >= renderSize.height
        else {
            invalidate()
            return false
        }
        if renderSize == preparedInputSize, outputSize == preparedOutputSize,
            isPrepared {
            return true
        }

        #if canImport(MetalFX)
            let descriptor = MTLFXSpatialScalerDescriptor()
            descriptor.inputWidth = Int(renderSize.width)
            descriptor.inputHeight = Int(renderSize.height)
            descriptor.outputWidth = Int(outputSize.width)
            descriptor.outputHeight = Int(outputSize.height)
            descriptor.colorTextureFormat = colorFormat
            descriptor.outputTextureFormat = colorFormat
            // sRGB-encoded color content (bgra8Unorm_srgb pipeline).
            descriptor.colorProcessingMode = .perceptual

            let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: colorFormat,
                width: Int(renderSize.width), height: Int(renderSize.height),
                mipmapped: false
            )
            colorDescriptor.usage = [.renderTarget, .shaderRead]
            colorDescriptor.storageMode = .private

            let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: depthFormat,
                width: Int(renderSize.width), height: Int(renderSize.height),
                mipmapped: false
            )
            depthDescriptor.usage = [.renderTarget]
            depthDescriptor.storageMode = .private

            let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: colorFormat,
                width: Int(outputSize.width), height: Int(outputSize.height),
                mipmapped: false
            )
            outputDescriptor.usage = [.renderTarget, .shaderWrite]
            outputDescriptor.storageMode = .private

            guard
                let scaler = descriptor.makeSpatialScaler(device: device),
                let color = device.makeTexture(descriptor: colorDescriptor),
                let depth = device.makeTexture(descriptor: depthDescriptor),
                let out = device.makeTexture(descriptor: outputDescriptor)
            else {
                invalidate()
                return false
            }
            color.label = "metalfx-input-color"
            depth.label = "metalfx-input-depth"
            out.label = "metalfx-output"
            scaler.colorTexture = color
            scaler.outputTexture = out

            self.scaler = scaler
            inputColor = color
            inputDepth = depth
            output = out
            preparedInputSize = renderSize
            preparedOutputSize = outputSize
            return true
        #else
            invalidate()
            return false
        #endif
    }

    var isPrepared: Bool {
        #if canImport(MetalFX)
            return scaler != nil && inputColor != nil && inputDepth != nil && output != nil
        #else
            return false
        #endif
    }

    /// Render pass targeting the scaled scene textures.
    func scenePassDescriptor(clearColor: MTLClearColor) -> MTLRenderPassDescriptor? {
        guard isPrepared, let inputColor, let inputDepth else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = inputColor
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = clearColor
        pass.depthAttachment.texture = inputDepth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1
        return pass
    }

    /// Encodes the spatial upscale (input → output). Returns false when the
    /// stage is not prepared.
    @discardableResult
    func encodeUpscale(into commandBuffer: MTLCommandBuffer) -> Bool {
        #if canImport(MetalFX)
            guard let scaler, isPrepared else { return false }
            scaler.encode(commandBuffer: commandBuffer)
            return true
        #else
            return false
        #endif
    }

    /// Drops the scaler and textures (scale disabled or sizes changing).
    func invalidate() {
        #if canImport(MetalFX)
            scaler = nil
        #endif
        inputColor = nil
        inputDepth = nil
        output = nil
        preparedInputSize = .zero
        preparedOutputSize = .zero
    }
}

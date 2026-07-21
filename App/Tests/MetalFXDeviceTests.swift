import Metal
import XCTest
@testable import CyberTopology

/// Device-only MetalFX spatial upscaling test (task 2.5). The MetalFX
/// framework does not exist in the simulator SDK, so this skips there
/// LOUDLY with an explicit reason — never silently (design D9, QA spec
/// "No silent skips"). The simulator suite covers the fallback decision and
/// the plain scaled-render path instead (`ResolutionScaleTests`).
final class MetalFXDeviceTests: XCTestCase {
    static let unsupportedSkipReason =
        "device-only: MetalFX spatial upscaling is absent from the simulator "
        + "SDK / unsupported on this GPU; the fallback path is covered by "
        + "ResolutionScaleTests (design D9 device release gate)"

    @MainActor
    func testSpatialUpscalerProducesFullResolutionFrameOnDevice() throws {
        let renderer = try XCTUnwrap(ViewportRenderer(), "Metal device unavailable")
        guard renderer.capabilities.supportsMetalFXSpatial else {
            throw XCTSkip(Self.unsupportedSkipReason)
        }

        renderer.resolutionScale = 0.5
        XCTAssertEqual(renderer.activeUpscalerKind, .metalFXSpatial)
        renderer.loadGeometry(
            positions: [0, 0, 0, 1, 0, 0, 0, 1, 0],
            normals: [0, 0, 1, 0, 0, 1, 0, 0, 1],
            colors: [1, 0, 0, 0, 1, 0, 0, 0, 1],
            indices: [0, 1, 2]
        )

        // Scene renders at 128×128, upscaled to a 256×256 "drawable".
        let device = renderer.device
        let drawableDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: ViewportRenderer.colorPixelFormat,
            width: 256, height: 256, mipmapped: false
        )
        drawableDescriptor.usage = [.renderTarget]
        drawableDescriptor.storageMode = .private
        let drawableTexture = try XCTUnwrap(device.makeTexture(descriptor: drawableDescriptor))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())

        renderer.setViewportSize(CGSize(width: 256, height: 256))
        XCTAssertTrue(
            renderer.encodeUpscaledFrame(to: drawableTexture, commandBuffer: commandBuffer)
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed)
        XCTAssertTrue(renderer.upscalerStage.isPrepared)
    }
}

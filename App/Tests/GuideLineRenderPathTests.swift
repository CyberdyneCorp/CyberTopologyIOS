import Foundation
import Metal
import Testing
import simd

@testable import CyberTopology

/// Guide-line overlay tests (add-guide-stroke-authoring): pure uniform math,
/// geometry load/clear, and an offscreen render asserting amber guide lines
/// appear. GPU tests run on the simulator's plain pipeline by design.
@MainActor
struct GuideLineRenderPathTests {
    private func makeRenderer() throws -> ViewportRenderer {
        try #require(ViewportRenderer(), "Metal device unavailable")
    }

    /// A diagonal guide line across the z=0 plane (one segment, two vertices).
    private static let linePositions: [Float] = [-0.5, -0.5, 0, /**/ 0.5, 0.5, 0]
    private static let lineIndices: [UInt32] = [0, 1]

    private func frameCameraOnLine(_ renderer: ViewportRenderer) throws {
        renderer.setViewportSize(CGSize(width: 128, height: 128))
        let bounds = try #require(SceneBounds(positions: Self.linePositions))
        renderer.camera = CameraState.framing(bounds, aspect: 1)
    }

    private func classifyAgainst(_ background: [UInt8], frame: [UInt8]) -> (warm: Int, cool: Int) {
        var warm = 0, cool = 0
        for base in stride(from: 0, to: min(frame.count, background.count), by: 4)
        where frame[base..<base + 4] != background[base..<base + 4] {
            let blue = Int(frame[base]), red = Int(frame[base + 2])
            if red > blue + 30 { warm += 1 }
            if blue > red + 30 { cool += 1 }
        }
        return (warm, cool)
    }

    // MARK: - Pure uniform math

    @Test("Guide uniforms carry the mvp, colour, and depth bias")
    func uniformsCarryColorAndBias() {
        let mvp = matrix_identity_float4x4
        let color = SIMD4<Float>(1.0, 0.62, 0.24, 0.95)
        let u = GuideLineUniformsFactory.uniforms(mvp: mvp, color: color, depthBias: 0.003)
        #expect(u.mvp == mvp)
        #expect(u.color == color)
        #expect(u.params.x == 0.003)
    }

    // MARK: - Geometry load / clear

    @Test("Loading guide lines sets geometry; clearing removes it")
    func loadAndClear() throws {
        let renderer = try makeRenderer()
        #expect(!renderer.hasGuideLines)
        renderer.loadGuideLines(positions: Self.linePositions, indices: Self.lineIndices)
        #expect(renderer.hasGuideLines)
        #expect(renderer.guideLinePath.indexCount == 2)
        #expect(renderer.guideLinePath.vertexCount == 2)
        renderer.clearGuideLines()
        #expect(!renderer.hasGuideLines)
    }

    @Test("Empty guide geometry clears rather than loading")
    func emptyClears() throws {
        let renderer = try makeRenderer()
        renderer.loadGuideLines(positions: Self.linePositions, indices: Self.lineIndices)
        #expect(renderer.hasGuideLines)
        renderer.loadGuideLines(positions: [], indices: [])
        #expect(!renderer.hasGuideLines)
    }

    @Test("A same-size reload does not reallocate buffers")
    func reloadDoesNotReallocate() throws {
        let renderer = try makeRenderer()
        renderer.loadGuideLines(positions: Self.linePositions, indices: Self.lineIndices)
        let allocationsAfterFirst = renderer.guideLinePath.bufferPool.allocationCount
        renderer.loadGuideLines(positions: Self.linePositions, indices: Self.lineIndices)
        #expect(renderer.guideLinePath.bufferPool.allocationCount == allocationsAfterFirst)
    }

    // MARK: - Offscreen render (GPU)

    @Test("A rendered guide line shows amber pixels")
    func renderShowsAmberLine() throws {
        let renderer = try makeRenderer()
        try frameCameraOnLine(renderer)
        // Background with no guides.
        let background = try #require(renderer.renderOffscreen(width: 128, height: 128, at: 0))

        // With a guide line loaded, amber ("warm") pixels appear.
        renderer.loadGuideLines(positions: Self.linePositions, indices: Self.lineIndices)
        let frame = try #require(renderer.renderOffscreen(width: 128, height: 128, at: 0))
        let (warm, cool) = classifyAgainst(background, frame: frame)
        #expect(warm > 0, "the amber guide line should add warm pixels")
        #expect(warm > cool, "the guide line is amber, not cool")
    }
}

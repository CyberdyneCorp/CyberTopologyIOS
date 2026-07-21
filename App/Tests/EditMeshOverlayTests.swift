import CyberKit
import Metal
import Testing
import simd
@testable import CyberTopology

/// EditMesh overlay pipeline tests (task 2.3): pure state/uniform math plus
/// offscreen renders on the plain vertex pipeline (the simulator/fallback
/// path by design), asserting wireframe visibility, occlusion threshold,
/// x-ray mode, and the time-uniform creation animation.
@MainActor
struct EditMeshOverlayTests {
    private func makeRenderer() throws -> ViewportRenderer {
        try #require(ViewportRenderer(), "Metal device unavailable")
    }

    private func seedMesh() throws -> Mesh {
        try Mesh.loadOBJ(at: UITestSupport.writeSeedOBJ())
    }

    /// Unit-quad wireframe (4 verts, 4 edges) used as overlay geometry.
    private static let quadPositions: [Float] = [
        0, 0, 0, /**/ 1, 0, 0, /**/ 1, 1, 0, /**/ 0, 1, 0,
    ]
    private static let quadEdges: [UInt32] = [0, 1, 1, 2, 2, 3, 3, 0]

    /// The quad wireframe shrunk around its center and pushed `depth` world
    /// units along the camera's forward axis (the Target's far side), so
    /// its projection stays inside the Target quad's silhouette.
    private func farSideQuad(forward: SIMD3<Float>, depth: Float) -> [Float] {
        let center = SIMD3<Float>(0.5, 0.5, 0)
        var out: [Float] = []
        for base in stride(from: 0, to: Self.quadPositions.count, by: 3) {
            let p = SIMD3(
                Self.quadPositions[base],
                Self.quadPositions[base + 1],
                Self.quadPositions[base + 2]
            )
            let shrunk = center + (p - center) * 0.5 + forward * depth
            out.append(contentsOf: [shrunk.x, shrunk.y, shrunk.z])
        }
        return out
    }

    /// Count of 4-byte pixels that differ between two frames.
    private func differingPixels(_ a: [UInt8], _ b: [UInt8]) -> Int {
        var count = 0
        for base in stride(from: 0, to: min(a.count, b.count), by: 4)
        where a[base..<base + 4] != b[base..<base + 4] {
            count += 1
        }
        return count
    }

    /// Time far past any creation animation (progress fully 1).
    private static let settled: Double = 1_000

    // MARK: - Animation math (time-uniform progression)

    @Test func animationProgressIsClampedAndMonotonic() {
        #expect(OverlayAnimation.progress(creationTime: nil, now: 5) == 1)
        #expect(OverlayAnimation.progress(creationTime: 10, now: 9) == 0)
        #expect(OverlayAnimation.progress(creationTime: 10, now: 10) == 0)

        var previous: Float = -1
        for step in 0...20 {
            let now = 10 + Double(step) / 20 * OverlayAnimation.duration
            let progress = OverlayAnimation.progress(creationTime: 10, now: now)
            #expect(progress >= previous, "progress must be non-decreasing in time")
            previous = progress
        }
        #expect(previous == 1)
        #expect(
            OverlayAnimation.progress(
                creationTime: 10, now: 10 + OverlayAnimation.duration * 2
            ) == 1
        )
    }

    @Test func animationProgressMidwayIsPartial() {
        let mid = OverlayAnimation.progress(
            creationTime: 0, now: OverlayAnimation.duration / 2
        )
        #expect(abs(mid - 0.5) < 0.001)
    }

    // MARK: - Uniform math

    @Test func mainUniformsCarrySettingsAndProgress() {
        let settings = OverlaySettings(opacity: 0.6, xrayEnabled: false, occlusionBias: 0.004)
        let uniforms = OverlayUniformsFactory.main(
            mvp: matrix_identity_float4x4, settings: settings,
            animationProgress: 0.25, vertexCount: 42
        )
        #expect(uniforms.color.w == 0.6)
        #expect(
            SIMD3(uniforms.color.x, uniforms.color.y, uniforms.color.z)
                == OverlayUniformsFactory.wireColor
        )
        #expect(uniforms.params.x == 0.25)
        #expect(uniforms.params.y == 0.004)
        #expect(uniforms.params.z == OverlayUniformsFactory.xrayAttenuation)
        #expect(uniforms.params.w == 42)
        #expect(uniforms.misc.x == OverlayUniformsFactory.pointSize)
        #expect(uniforms.misc.y == 0)
    }

    @Test func xrayUniformsDifferOnlyByPassFlag() {
        let settings = OverlaySettings(opacity: 1, xrayEnabled: true, occlusionBias: 0.002)
        var expected = OverlayUniformsFactory.main(
            mvp: matrix_identity_float4x4, settings: settings,
            animationProgress: 1, vertexCount: 4
        )
        let xray = OverlayUniformsFactory.xray(
            mvp: matrix_identity_float4x4, settings: settings,
            animationProgress: 1, vertexCount: 4
        )
        #expect(xray.misc.y == 1)
        expected.misc.y = 1
        #expect(xray == expected)
    }

    @Test func overlaySettingsDefaultsMatchPersistedDefaults() {
        let settings = OverlaySettings()
        #expect(settings.opacity == Float(ViewportSettings.defaultOverlayOpacity))
        #expect(settings.occlusionBias == Float(ViewportSettings.defaultOcclusionBias))
        #expect(!settings.xrayEnabled)
    }

    // MARK: - Overlay state on the renderer

    @Test func loadOverlayFromEngineMeshExposesAuthoredEdges() throws {
        let renderer = try makeRenderer()
        renderer.loadOverlay(mesh: try seedMesh(), at: 10)
        #expect(renderer.hasOverlay)
        // The seeded quad has 4 authored edges (8 line indices), 4 vertices
        // — never 5 edges (no fan diagonal).
        #expect(renderer.overlayPath.edgeIndexCount == 8)
        #expect(renderer.overlayPath.vertexCount == 4)
        #expect(renderer.overlayCreationTime == 10)
    }

    @Test func reloadWithoutRestartKeepsAnimationClock() throws {
        let renderer = try makeRenderer()
        renderer.loadOverlay(mesh: try seedMesh(), at: 10)
        renderer.loadOverlay(mesh: try seedMesh(), restartAnimation: false, at: 20)
        #expect(renderer.overlayCreationTime == 10)
        renderer.loadOverlay(mesh: try seedMesh(), at: 30)
        #expect(renderer.overlayCreationTime == 30)
    }

    @Test func emptyOverlayLoadClears() throws {
        let renderer = try makeRenderer()
        renderer.loadOverlayGeometry(positions: Self.quadPositions, edges: Self.quadEdges)
        #expect(renderer.hasOverlay)
        renderer.loadOverlay(mesh: try Mesh())
        #expect(!renderer.hasOverlay)
        #expect(renderer.overlayCreationTime == nil)
    }

    @Test func clearOverlayResetsState() throws {
        let renderer = try makeRenderer()
        renderer.loadOverlayGeometry(positions: Self.quadPositions, edges: Self.quadEdges)
        renderer.clearOverlay()
        #expect(!renderer.hasOverlay)
        #expect(renderer.overlayCreationTime == nil)
    }

    @Test func isOverlayAnimatingTracksTheClock() throws {
        let renderer = try makeRenderer()
        renderer.loadOverlayGeometry(
            positions: Self.quadPositions, edges: Self.quadEdges, at: 100
        )
        #expect(renderer.isOverlayAnimating(at: 100.01))
        #expect(!renderer.isOverlayAnimating(at: 100 + OverlayAnimation.duration))
    }

    @Test func overlayLoadsDoNotReallocateOnSameSizeReload() throws {
        let renderer = try makeRenderer()
        renderer.loadOverlayGeometry(positions: Self.quadPositions, edges: Self.quadEdges)
        let allocations = renderer.overlayPath.bufferPool.allocationCount
        renderer.loadOverlayGeometry(positions: Self.quadPositions, edges: Self.quadEdges)
        #expect(renderer.renderOffscreen(width: 32, height: 32, at: Self.settled) != nil)
        #expect(renderer.overlayPath.bufferPool.allocationCount == allocations)
    }

    // MARK: - Offscreen renders

    @Test func wireframeRendersVisiblyOverTheTarget() throws {
        let renderer = try makeRenderer()
        renderer.load(mesh: try seedMesh())
        let targetOnly = try #require(
            renderer.renderOffscreen(width: 128, height: 128, at: Self.settled)
        )
        renderer.loadOverlayGeometry(
            positions: Self.quadPositions, edges: Self.quadEdges, at: 0
        )
        let withWire = try #require(
            renderer.renderOffscreen(width: 128, height: 128, at: Self.settled)
        )
        #expect(differingPixels(withWire, targetOnly) > 50)
    }

    @Test func zeroOpacityHidesTheOverlay() throws {
        let renderer = try makeRenderer()
        renderer.load(mesh: try seedMesh())
        let targetOnly = try #require(
            renderer.renderOffscreen(width: 96, height: 96, at: Self.settled)
        )
        renderer.loadOverlayGeometry(
            positions: Self.quadPositions, edges: Self.quadEdges, at: 0
        )
        renderer.overlaySettings.opacity = 0
        let frame = try #require(
            renderer.renderOffscreen(width: 96, height: 96, at: Self.settled)
        )
        #expect(differingPixels(frame, targetOnly) == 0)
    }

    /// Spec scenario "X-ray mode": far-side wireframe is occluded with
    /// x-ray off and visible (depth-attenuated pass) with x-ray on — two
    /// offscreen frames, compared.
    @Test func xrayRevealsFarSideWireframe() throws {
        let renderer = try makeRenderer()
        renderer.load(mesh: try seedMesh())
        let targetOnly = try #require(
            renderer.renderOffscreen(width: 128, height: 128, at: Self.settled)
        )

        // Wireframe well behind the Target (far side from the camera),
        // beyond any occlusion bias, projecting inside its silhouette.
        let forward = renderer.camera.basis.forward
        renderer.loadOverlayGeometry(
            positions: farSideQuad(forward: forward, depth: 0.3),
            edges: Self.quadEdges, at: 0
        )

        renderer.overlaySettings.xrayEnabled = false
        let xrayOff = try #require(
            renderer.renderOffscreen(width: 128, height: 128, at: Self.settled)
        )
        renderer.overlaySettings.xrayEnabled = true
        let xrayOn = try #require(
            renderer.renderOffscreen(width: 128, height: 128, at: Self.settled)
        )

        // Occluded by default…
        #expect(differingPixels(xrayOff, targetOnly) < 10)
        // …and revealed by x-ray.
        #expect(differingPixels(xrayOn, xrayOff) > 50)
    }

    /// Occlusion depth threshold: a wireframe slightly behind the surface
    /// is occluded at bias 0 and visible at the maximum configurable bias.
    @Test func occlusionBiasKeepsNearbyBuriedEdgesVisible() throws {
        let renderer = try makeRenderer()
        renderer.load(mesh: try seedMesh())
        let forward = renderer.camera.basis.forward
        renderer.loadOverlayGeometry(
            positions: farSideQuad(forward: forward, depth: 0.005),
            edges: Self.quadEdges, at: 0
        )

        renderer.overlaySettings.xrayEnabled = false
        renderer.overlaySettings.occlusionBias = 0
        let hardOcclusion = try #require(
            renderer.renderOffscreen(width: 128, height: 128, at: Self.settled)
        )
        renderer.overlaySettings.occlusionBias =
            Float(ViewportSettings.occlusionBiasRange.upperBound)
        let forgiving = try #require(
            renderer.renderOffscreen(width: 128, height: 128, at: Self.settled)
        )
        #expect(differingPixels(forgiving, hardOcclusion) > 50)
    }

    /// Spec scenario "Wireframe animation on creation": the reveal is
    /// driven by the time uniform — frames at progress 0, mid and 1 differ,
    /// and the mid frame shows strictly less wireframe than the settled one.
    @Test func creationAnimationProgressesWithTheTimeUniform() throws {
        let renderer = try makeRenderer()
        renderer.load(mesh: try seedMesh())
        let creation = 100.0
        renderer.loadOverlayGeometry(
            positions: Self.quadPositions, edges: Self.quadEdges, at: creation
        )

        let atStart = try #require(
            renderer.renderOffscreen(width: 128, height: 128, at: creation)
        )
        let midway = try #require(
            renderer.renderOffscreen(
                width: 128, height: 128, at: creation + OverlayAnimation.duration / 2
            )
        )
        let settled = try #require(
            renderer.renderOffscreen(
                width: 128, height: 128, at: creation + OverlayAnimation.duration
            )
        )

        let startVsSettled = differingPixels(atStart, settled)
        let midVsStart = differingPixels(midway, atStart)
        let midVsSettled = differingPixels(midway, settled)
        // Sweep has revealed something by midway…
        #expect(midVsStart > 0)
        // …but not everything.
        #expect(midVsSettled > 0)
        // Fully settled differs most from the un-revealed start.
        #expect(startVsSettled > midVsStart)
    }
}

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

    // MARK: - Screen-space feature sizing

    /// REGRESSION: edge width and vertex-dot diameter were authored in
    /// PIXELS, so the wire rendered a third as heavy on a 3x display as the
    /// numbers implied — a hairline on the devices this app actually runs
    /// on. Sizes are points now, resolved to pixels against the live
    /// content scale.
    @Test func screenFeaturesAreSizedInPointsNotPixels() {
        let settings = OverlaySettings()
        let retina = OverlayViewport(sizePixels: SIMD2(2048, 1536), scale: 2)
        let uniforms = OverlayUniformsFactory.main(
            mvp: matrix_identity_float4x4, settings: settings,
            animationProgress: 1, vertexCount: 4, viewport: retina
        )
        #expect(uniforms.misc.x == OverlayUniformsFactory.pointSize * 2)
        #expect(uniforms.line.x == OverlayUniformsFactory.edgeWidth * 2)
        // The ribbon expansion is in pixels, so the shader needs the
        // drawable size — zero here would collapse every edge to nothing.
        #expect(uniforms.line.y == 2048)
        #expect(uniforms.line.z == 1536)
    }

    /// A resolution-scale change must not thin the wire along with the
    /// render target: the same edge is the same physical weight at 50%.
    @Test func featureSizesTrackContentScaleNotDrawableSize() {
        let settings = OverlaySettings()
        let full = OverlayUniformsFactory.main(
            mvp: matrix_identity_float4x4, settings: settings,
            animationProgress: 1, vertexCount: 4,
            viewport: OverlayViewport(sizePixels: SIMD2(2048, 1536), scale: 2)
        )
        let halved = OverlayUniformsFactory.main(
            mvp: matrix_identity_float4x4, settings: settings,
            animationProgress: 1, vertexCount: 4,
            viewport: OverlayViewport(sizePixels: SIMD2(1024, 768), scale: 1)
        )
        // Half the pixels, half the scale: half the pixel width — which is
        // the SAME width in points, and therefore on screen.
        #expect(halved.line.x == full.line.x / 2)
        #expect(halved.misc.x == full.misc.x / 2)
    }

    /// Passes that redraw edges the base wire already covered must be
    /// heavier than it, or a tagged loop is invisible under its own wire.
    @Test func markingPassesDrawHeavierThanTheBaseWire() {
        let settings = OverlaySettings()
        let viewport = OverlayViewport(sizePixels: SIMD2(1024, 768), scale: 1)
        let wire = OverlayUniformsFactory.main(
            mvp: matrix_identity_float4x4, settings: settings,
            animationProgress: 1, vertexCount: 4, viewport: viewport
        )
        let tagged = OverlayUniformsFactory.tagged(
            mvp: matrix_identity_float4x4, settings: settings,
            animationProgress: 1, vertexCount: 4, viewport: viewport
        )
        let hover = OverlayUniformsFactory.hover(
            mvp: matrix_identity_float4x4, settings: settings, viewport: viewport
        )
        #expect(tagged.line.x > wire.line.x)
        #expect(hover.line.x > wire.line.x)
        // Pins are THE element to spot: bigger than a plain vertex dot.
        let pins = OverlayUniformsFactory.pins(
            mvp: matrix_identity_float4x4, settings: settings, viewport: viewport
        )
        #expect(pins.misc.x > wire.misc.x)
    }

    /// The renderer must publish real metrics, or every screen-space size
    /// silently falls back to the 1x1 placeholder viewport.
    @Test func theRendererPublishesItsViewportMetrics() throws {
        let renderer = try makeRenderer()
        renderer.contentScale = 3
        renderer.setViewportSize(CGSize(width: 1200, height: 900))

        #expect(renderer.overlayViewport.sizePixels == SIMD2(1200, 900))
        #expect(renderer.overlayViewport.scale == 3)
    }

    /// REGRESSION-guard for the MetalFX path: it renders into a texture
    /// SMALLER than the drawable and upscales the result. Sizing ribbons
    /// against the drawable there would expand them against a viewport
    /// they are not rasterizing into, and the upscaler would magnify an
    /// already-too-thin wire. Both terms scale together instead, so the
    /// on-screen width is unchanged.
    @Test func reducedResolutionRendersTheSameOnScreenWidth() throws {
        let renderer = try makeRenderer()
        renderer.contentScale = 2
        renderer.setViewportSize(CGSize(width: 1000, height: 800))

        let full = renderer.overlayViewport
        let halved = renderer.overlayViewport(renderTargetPixels: SIMD2(500, 400))

        #expect(halved.sizePixels == SIMD2(500, 400))
        // Half the render pixels per point, so half the pixel width — the
        // same fraction of the (half-sized) target, and the same width on
        // screen once upscaled.
        #expect(halved.scale == full.scale / 2)
        #expect(
            halved.pixels(OverlayUniformsFactory.edgeWidth) / halved.sizePixels.x
                == full.pixels(OverlayUniformsFactory.edgeWidth) / full.sizePixels.x
        )
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

    /// REGRESSION, and the end-to-end proof that edges are ribbons rather
    /// than `.line` primitives: Metal exposes no line width, so a line list
    /// rasterizes exactly one pixel wide no matter what any uniform says.
    /// Every width assertion elsewhere in this suite is uniform math and
    /// would still pass against the old one-pixel wire — only counting lit
    /// pixels distinguishes them.
    ///
    /// Same geometry, same render size, three times the content scale: a
    /// hardware line list renders identically (1px), the ribbon pipeline
    /// renders visibly heavier.
    @Test func edgeWidthActuallyChangesWhatIsRasterized() throws {
        func wireCoverage(contentScale: Float) throws -> Int {
            let renderer = try makeRenderer()
            renderer.contentScale = contentScale
            renderer.load(mesh: try seedMesh())
            let targetOnly = try #require(
                renderer.renderOffscreen(width: 256, height: 256, at: Self.settled)
            )
            renderer.loadOverlayGeometry(
                positions: Self.quadPositions, edges: Self.quadEdges, at: 0
            )
            let withWire = try #require(
                renderer.renderOffscreen(width: 256, height: 256, at: Self.settled)
            )
            return differingPixels(withWire, targetOnly)
        }

        let thin = try wireCoverage(contentScale: 1)
        let thick = try wireCoverage(contentScale: 3)
        #expect(thin > 0)
        // Not asserted as an exact ratio: the dots, the antialiased ribbon
        // edges and the depth test all contribute. A clear majority more
        // coverage is the property that matters.
        #expect(thick > thin * 2)
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

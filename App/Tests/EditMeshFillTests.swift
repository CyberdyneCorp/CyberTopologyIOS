import CyberKit
import CyberKitTesting
import Testing
import simd
@testable import CyberTopology

/// Translucent EditMesh face fill (spec: viewport-rendering / "Animated
/// EditMesh overlay pipeline").
///
/// The wireframe alone is hard to read against a light Target; the fill
/// makes each authored face read as a surface while keeping the Target
/// visible through it. These assert the properties that make that true.
@MainActor
struct EditMeshFillTests {
    private func renderer() throws -> ViewportRenderer {
        try #require(ViewportRenderer())
    }

    private func cage() throws -> Mesh {
        try Mesh.loadOBJ(at: MeshFixtureCorpus.stanfordBunnyURL())
    }

    /// The fill loads from the same call as the wireframe, so a wireframe
    /// can never appear without its fill.
    @Test func loadingTheOverlayAlsoLoadsTheFill() throws {
        let renderer = try renderer()
        renderer.overlaySettings.fillOpacity = 0.3
        renderer.loadOverlay(mesh: try cage())

        #expect(renderer.hasOverlay)
        #expect(renderer.hasEditMeshFill)
    }

    /// Opacity 0 is the pre-fill behaviour: wireframe only, and crucially
    /// NO geometry uploaded — an invisible pass must not cost bandwidth.
    @Test func zeroOpacityLoadsNoFillGeometry() throws {
        let renderer = try renderer()
        renderer.overlaySettings.fillOpacity = 0
        renderer.loadOverlay(mesh: try cage())

        #expect(renderer.hasOverlay)
        #expect(!renderer.hasEditMeshFill)
    }

    /// The style must carry the requested opacity through, or the slider
    /// moves nothing.
    @Test func opacityReachesTheStyle() throws {
        let renderer = try renderer()
        renderer.overlaySettings.fillOpacity = 0.55
        renderer.loadOverlay(mesh: try cage())

        #expect(abs(renderer.editMeshFillStyle.baseAlpha - 0.55) < 1e-5)
    }

    /// REQUIRED, not cosmetic: authored faces are snapped ONTO the Target,
    /// so a fill drawn at exactly the same depth z-fights into speckle.
    /// The lift is scale-free (a fraction of the scene radius).
    @Test func theFillIsLiftedOffTheTarget() throws {
        let renderer = try renderer()
        renderer.overlaySettings.fillOpacity = 0.3
        renderer.loadOverlay(mesh: try cage())

        #expect(renderer.editMeshFillStyle.normalOffset > 0)
    }

    /// Committed geometry must not animate: a pulsing fill would pin the
    /// display link for decoration and fight the render-on-demand pacing.
    @Test func theFillNeverPulses() {
        #expect(GhostStyle.editMeshFill.pulsePeriod == 0)
    }

    /// The spec requires solver proposals to stay visually distinct from
    /// committed geometry, so the fill must not reuse the ghost tint.
    @Test func theFillIsDistinctFromGhostProposals() {
        #expect(GhostStyle.editMeshFill.color != GhostStyle.proposal.color)
        #expect(GhostStyle.editMeshFill.color != GhostStyle.subdivisionPreview.color)
    }

    /// Opacity is clamped: a malformed persisted preference must not
    /// produce an out-of-range alpha.
    @Test func opacityIsClamped() {
        #expect(GhostStyle.editMeshFill(sceneRadius: 1, opacity: 5).baseAlpha == 1)
        #expect(GhostStyle.editMeshFill(sceneRadius: 1, opacity: -3).baseAlpha == 0)
    }

    /// Dropping opacity to zero after a load must release the geometry,
    /// not merely render it invisibly.
    @Test func clearingReleasesTheFill() throws {
        let renderer = try renderer()
        renderer.overlaySettings.fillOpacity = 0.4
        renderer.loadOverlay(mesh: try cage())
        #expect(renderer.hasEditMeshFill)

        renderer.clearEditMeshFill()
        #expect(!renderer.hasEditMeshFill)
        // The wireframe is unaffected — they are separate reads.
        #expect(renderer.hasOverlay)
    }

    /// REGRESSION: an authored quad rendered as an outline with the TARGET
    /// showing through it — the fill sank inside the surface it was
    /// snapped onto — because occlusion was fought entirely in world space,
    /// with a lift along the vertex normal.
    ///
    /// A normal lift buys depth clearance only in proportion to how much
    /// the normal faces the camera: at a grazing angle it slides the
    /// surface sideways and gains nothing, which is exactly where the
    /// failure was visible. The wireframe never had the problem because it
    /// has always pulled toward the camera in DEPTH space instead.
    ///
    /// So the invariant is not "the lift is big enough" — no lift is, at 90
    /// degrees — but that the fill carries a depth bias at all, and that it
    /// is the same one the wire outlining it uses. Same bias, same
    /// visibility: the interior is drawn wherever the outline is.
    @Test func theFillTakesTheSameOcclusionBiasAsItsWireframe() {
        let settings = OverlaySettings(occlusionBias: 0.006)
        let style = GhostStyle.editMeshFill(sceneRadius: 1, opacity: 0.5)
            .withDepthBias(settings.occlusionBias)

        #expect(style.depthBias == settings.occlusionBias)

        // And it reaches the GPU, in the slot the shader reads.
        let uniforms = GhostUniformsFactory.uniforms(
            mvp: matrix_identity_float4x4, viewDirection: SIMD3(0, 0, -1),
            style: style, time: 0
        )
        #expect(uniforms.params.z == settings.occlusionBias)
    }

    /// The lift's remaining job is only to break coplanarity with the
    /// Target, so it stays small enough that a filled face reads as lying
    /// ON the surface. It was inflated to 2% of the scene radius while it
    /// was (wrongly) carrying occlusion, which made faces visibly float.
    @Test func theFillHugsTheSurfaceRatherThanFloatingOverIt() {
        let lift = GhostStyle.editMeshFill(sceneRadius: 10, opacity: 1).normalOffset
        #expect(lift > 0)
        #expect(lift < 0.01 * 10)
    }

    /// The fill has its OWN buffer pool, so adding it must not change the
    /// overlay's per-frame upload accounting (which
    /// `MeshEditControllerTests` asserts to an exact count).
    @Test func theFillDoesNotShareTheOverlayPool() throws {
        let renderer = try renderer()
        renderer.overlaySettings.fillOpacity = 0.3
        renderer.loadOverlay(mesh: try cage())

        #expect(renderer.editMeshFillPath.bufferPool !== renderer.overlayPath.bufferPool)
    }
}

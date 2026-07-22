import CyberKit
import CyberKitTesting
import Testing
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

import CyberKit
import CyberKitTesting
import Foundation
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

    /// REGRESSION (device: translucent face shading lingered after deleting
    /// every face / reimporting the Target — a wireframe-less ghost fill):
    /// `clearOverlay`, the teardown run when the EditMesh goes away, must
    /// release the fill too, not only the wireframe. The two are loaded as a
    /// pair, so they must be cleared as a pair.
    @Test func clearingTheOverlayAlsoClearsTheFill() throws {
        let renderer = try renderer()
        renderer.overlaySettings.fillOpacity = 0.4
        renderer.loadOverlay(mesh: try cage())
        #expect(renderer.hasOverlay)
        #expect(renderer.hasEditMeshFill)

        renderer.clearOverlay()
        #expect(!renderer.hasOverlay, "the wireframe is gone")
        #expect(!renderer.hasEditMeshFill, "and so is its fill — no ghost faces linger")
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

// MARK: - Occlusion by the Target (openspec fix-target-occlusion)

extension EditMeshFillTests {
    private func differingPixels(_ a: [UInt8], _ b: [UInt8]) -> Int {
        var count = 0
        for base in stride(from: 0, to: min(a.count, b.count), by: 4)
        where a[base..<base + 4] != b[base..<base + 4] {
            count += 1
        }
        return count
    }

    /// A quad mesh centred on the Target's centre and pushed `depth` world units
    /// along the camera's forward axis, so it lies BEHIND the Target while still
    /// projecting inside its silhouette.
    private func farSideFill(
        forward: SIMD3<Float>, depth: Float, centre: SIMD3<Float> = SIMD3(0.5, 0.5, 0)
    ) throws -> Mesh {
        // Shrunk about the centre so its projection stays within the Target.
        let corners: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0),
        ].map { centre + ($0 - centre) * 0.5 + forward * depth }
        let obj =
            corners.map { "v \($0.x) \($0.y) \($0.z)" }.joined(separator: "\n")
            + "\nf 1 2 3 4\n"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("farside-fill-\(UUID().uuidString).obj")
        try obj.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Mesh.loadOBJ(at: url)
    }

    /// REPORTED FROM DEVICE: cage faces on the far side of the bunny read as if
    /// they were in front of it. The wireframe's occlusion has been covered since
    /// task 2.3 (`xrayRevealsFarSideWireframe`); the FILL — the surface actually
    /// seen in the report — had no such test.
    @Test func theFillIsOccludedByTheTarget() throws {
        let renderer = try renderer()
        renderer.load(mesh: try Mesh.loadOBJ(at: UITestSupport.writeSeedOBJ()))
        renderer.overlaySettings.xrayEnabled = false
        let targetOnly = try #require(
            renderer.renderOffscreen(width: 128, height: 128, at: 1_000)
        )

        let forward = renderer.camera.basis.forward
        renderer.loadEditMeshFill(mesh: try farSideFill(forward: forward, depth: 0.3), opacity: 0.9)
        let withFarSideFill = try #require(
            renderer.renderOffscreen(width: 128, height: 128, at: 1_000)
        )

        #expect(
            differingPixels(withFarSideFill, targetOnly) < 10,
            "a fill behind the Target must be hidden by it"
        )
    }

    /// THE REPORTED CASE. The bunny's ears and the curve of its back are THIN:
    /// the two surfaces are a few percent of the scene radius apart. The
    /// occlusion allowance is what decides whether a cage on the far surface
    /// punches through the near one, and as an NDC offset it is worth ~4.8% of
    /// the radius at the far surface — thicker than the feature itself.
    @Test func aFillBehindAThinFeatureIsStillOccluded() throws {
        let renderer = try renderer()
        // Target: two parallel surfaces 4% of the scene's size apart — an ear.
        let separation: Float = 0.04
        let obj = """
        v 0 0 0
        v 1 0 0
        v 1 1 0
        v 0 1 0
        v 0 0 \(-separation)
        v 1 0 \(-separation)
        v 1 1 \(-separation)
        v 0 1 \(-separation)
        f 1 2 3 4
        f 5 6 7 8
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("thin-target-\(UUID().uuidString).obj")
        try obj.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        renderer.load(mesh: try Mesh.loadOBJ(at: url))
        renderer.overlaySettings.xrayEnabled = false
        let targetOnly = try #require(
            renderer.renderOffscreen(width: 128, height: 128, at: 1_000)
        )

        // A cage lying on the FAR surface of that feature.
        let forward = renderer.camera.basis.forward
        renderer.loadEditMeshFill(
            mesh: try farSideFill(
                forward: forward, depth: separation, centre: SIMD3(0.5, 0.5, 0)
            ),
            opacity: 0.9
        )
        let withFill = try #require(
            renderer.renderOffscreen(width: 128, height: 128, at: 1_000)
        )

        #expect(
            differingPixels(withFill, targetOnly) < 10,
            "the cage on the far surface punched through a feature only \(separation) thick"
        )
    }

    /// THE REPORTED CONFIGURATION: the Occlusion depth slider at MAXIMUM.
    ///
    /// The device screenshot showed it maxed, and under the old NDC semantics
    /// that bought ~48% of the scene radius of see-through at the far surface —
    /// so far-side cage punched through the bunny, and X-ray appeared to do
    /// nothing because the depth-tested pass was already drawing everything.
    /// A maxed slider must loosen occlusion, never disable it.
    @Test func aMaxedOcclusionDepthStillOccludesTheFarSide() throws {
        let renderer = try renderer()
        renderer.load(mesh: try Mesh.loadOBJ(at: UITestSupport.writeSeedOBJ()))
        renderer.overlaySettings.xrayEnabled = false
        renderer.overlaySettings.occlusionBias = Float(
            ViewportSettings.occlusionBiasRange.upperBound
        )
        let targetOnly = try #require(
            renderer.renderOffscreen(width: 128, height: 128, at: 1_000)
        )

        let forward = renderer.camera.basis.forward
        renderer.loadEditMeshFill(
            mesh: try farSideFill(forward: forward, depth: 0.3), opacity: 0.9
        )
        let withFarSideFill = try #require(
            renderer.renderOffscreen(width: 128, height: 128, at: 1_000)
        )

        #expect(
            differingPixels(withFarSideFill, targetOnly) < 10,
            "at maximum occlusion depth the far-side cage punched through the Target"
        )
    }

    /// The counterweight: a fill in FRONT of the Target must still draw, or the
    /// occlusion fix would have "worked" by hiding everything.
    @Test func aFillInFrontOfTheTargetStillDraws() throws {
        let renderer = try renderer()
        renderer.load(mesh: try Mesh.loadOBJ(at: UITestSupport.writeSeedOBJ()))
        renderer.overlaySettings.xrayEnabled = false
        let targetOnly = try #require(
            renderer.renderOffscreen(width: 128, height: 128, at: 1_000)
        )

        let forward = renderer.camera.basis.forward
        renderer.loadEditMeshFill(
            mesh: try farSideFill(forward: forward, depth: -0.3), opacity: 0.9
        )
        let withNearFill = try #require(
            renderer.renderOffscreen(width: 128, height: 128, at: 1_000)
        )

        #expect(differingPixels(withNearFill, targetOnly) > 50)
    }
}

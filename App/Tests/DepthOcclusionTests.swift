import Foundation
import Testing
import simd
@testable import CyberTopology

/// Depth precision and the occlusion allowance (openspec fix-target-occlusion;
/// spec: viewport-rendering / "EditMesh geometry behind the Target is
/// occluded").
///
/// REPORTED FROM DEVICE: cage faces on the far side of the bunny read as if they
/// were in front of it. The cause was measurable rather than visual — at the
/// default framing the near plane collapsed to 6e-5, the whole model spanned
/// 4e-5 of NDC depth, and the occlusion allowance was 0.002: fifty times the
/// model's entire depth range, which disables the depth test rather than tuning
/// it.
@MainActor
struct DepthOcclusionTests {
    private let unitScene = SceneBounds(
        lower: SIMD3(repeating: -1), upper: SIMD3(repeating: 1)
    )

    /// NDC depth of a point `distance` in front of the camera.
    private func ndcDepth(
        _ distance: Float, camera: CameraState, bounds: SceneBounds
    ) -> Float {
        let point = camera.position + camera.basis.forward * distance
        let clip =
            camera.projectionMatrix(aspect: 1.33, bounds: bounds) * camera.viewMatrix()
            * SIMD4(point, 1)
        return clip.z / clip.w
    }

    /// The scene's own front-to-back depth range, in NDC.
    private func depthSpread(camera: CameraState, bounds: SceneBounds) -> Float {
        let toCentre = simd_distance(camera.position, bounds.center)
        let front = ndcDepth(toCentre - bounds.radius, camera: camera, bounds: bounds)
        let back = ndcDepth(toCentre + bounds.radius, camera: camera, bounds: bounds)
        return abs(back - front)
    }

    // MARK: - Precision

    @Test func theNearFarRatioStaysBoundedAtEveryPose() {
        var poses: [(String, CameraState)] = []
        poses.append(("fitted", CameraState.framing(unitScene, aspect: 1.33)))

        var inside = CameraState.framing(unitScene, aspect: 1.33)
        inside.distance = unitScene.radius * 0.1  // camera inside the model
        poses.append(("inside", inside))

        var far = CameraState.framing(unitScene, aspect: 1.33)
        far.distance = unitScene.radius * 50
        poses.append(("far", far))

        for (name, camera) in poses {
            let (near, farPlane) = camera.clipPlanes(for: unitScene)
            #expect(near > 0, "\(name): near collapsed")
            #expect(farPlane > near, "\(name): degenerate planes")
            #expect(
                farPlane / near <= 2000,
                "\(name): far/near = \(farPlane / near) leaves no depth resolution"
            )
        }
    }

    @Test func theFrontAndBackOfAFramedSceneDifferInDepth() {
        let camera = CameraState.framing(unitScene, aspect: 1.33)
        let spread = depthSpread(camera: camera, bounds: unitScene)
        #expect(
            spread > 1e-3,
            "the whole model spans \(spread) in NDC depth — nothing can be occluded reliably"
        )
    }

    // MARK: - The allowance

    /// THE measurement behind the device report: the allowance that keeps a
    /// surface-snapped cage visible must be a SMALL fraction of the model's own
    /// depth range. At 49.5x it hid nothing.
    @Test func theOcclusionAllowanceIsSmallAgainstTheSceneItBiases() {
        let camera = CameraState.framing(unitScene, aspect: 1.33)
        let spread = depthSpread(camera: camera, bounds: unitScene)
        let settings = OverlaySettings()
        let bias = camera.depthBias(
            forWorldOffset: settings.occlusionBias * unitScene.radius, bounds: unitScene
        )
        #expect(
            bias < spread / 10,
            """
            allowance \(bias) vs the scene's own depth spread \(spread) \
            (\(bias / spread)x) — the far side of the model survives the depth test
            """
        )
        #expect(bias > 0, "an allowance of zero z-fights a surface-snapped cage")
    }

    /// The same setting must mean the same thing on scenes of wildly different
    /// size — which is exactly what an NDC number cannot do.
    @Test func theAllowanceScalesWithTheScene() {
        let tiny = SceneBounds(
            lower: SIMD3(repeating: -0.001), upper: SIMD3(repeating: 0.001)
        )
        let huge = SceneBounds(
            lower: SIMD3(repeating: -100), upper: SIMD3(repeating: 100)
        )
        func ratio(_ bounds: SceneBounds) -> Float {
            let camera = CameraState.framing(bounds, aspect: 1.33)
            let bias = camera.depthBias(
                forWorldOffset: OverlaySettings().occlusionBias * bounds.radius,
                bounds: bounds
            )
            return bias / depthSpread(camera: camera, bounds: bounds)
        }
        let small = ratio(tiny)
        let large = ratio(huge)
        #expect(
            abs(small - large) < 1e-3,
            "the allowance is \(small) of a tiny scene but \(large) of a huge one"
        )
    }

    /// A cage lying ON the surface must still draw: the allowance exists for
    /// exactly that, so it must exceed the depth difference of a coincident
    /// surface (which is zero) with room for float error.
    @Test func aSurfaceSnappedOverlayStillPassesTheDepthTest() {
        let camera = CameraState.framing(unitScene, aspect: 1.33)
        let bias = camera.depthBias(
            forWorldOffset: OverlaySettings().occlusionBias * unitScene.radius,
            bounds: unitScene
        )
        // The depth difference across a hair's breadth of surface, which is what
        // a snapped cage sits within.
        let toCentre = simd_distance(camera.position, unitScene.center)
        let surface = ndcDepth(toCentre - unitScene.radius, camera: camera, bounds: unitScene)
        let hair = ndcDepth(
            toCentre - unitScene.radius + unitScene.radius * 1e-4,
            camera: camera, bounds: unitScene
        )
        #expect(bias > abs(hair - surface), "the allowance cannot even cover surface noise")
    }
}

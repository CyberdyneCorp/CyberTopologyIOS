import CyberKit
import Foundation
import Testing
import simd

@testable import CyberTopology

/// The 2D island grammar (openspec add-uv-island-editing, 6.3; spec: uv-workflow —
/// "stroke on upper part → rotate, lower → scale, middle → move").
///
/// All pure arithmetic, which is the point of the panel being a `Canvas`: the grammar is testable
/// without a view, a GPU or a gesture recognizer.
struct UVIslandGestureTests {
    private let box = (min: SIMD2<Float>(0.2, 0.2), max: SIMD2<Float>(0.6, 0.8))
    private var centre: SIMD2<Float> { (box.min + box.max) * 0.5 }

    // MARK: - Zone classification

    @Test("Upper third rotates, lower third scales, middle moves")
    func zonesFollowTheGrammar() {
        let u: Float = 0.4  // horizontal position is irrelevant to the classification
        // v UP: "upper" is HIGH v. Classifying in view space instead would swap rotate and scale,
        // because the panel flips v for drawing.
        #expect(UVIslandGesture.mode(forStartingAt: SIMD2(u, 0.78), in: box) == .rotate)
        #expect(UVIslandGesture.mode(forStartingAt: SIMD2(u, 0.50), in: box) == .move)
        #expect(UVIslandGesture.mode(forStartingAt: SIMD2(u, 0.22), in: box) == .scale)
    }

    @Test("The zone boundaries are exactly the thirds")
    func boundariesAreThirds() {
        let height = box.max.y - box.min.y
        let lower = box.min.y + height / 3
        let upper = box.min.y + 2 * height / 3
        // Inclusive on the outer side, so the extremes never fall through to `move`.
        #expect(UVIslandGesture.mode(forStartingAt: SIMD2(0.4, lower), in: box) == .scale)
        #expect(UVIslandGesture.mode(forStartingAt: SIMD2(0.4, upper), in: box) == .rotate)
        #expect(UVIslandGesture.mode(forStartingAt: SIMD2(0.4, box.min.y), in: box) == .scale)
        #expect(UVIslandGesture.mode(forStartingAt: SIMD2(0.4, box.max.y), in: box) == .rotate)
    }

    @Test("A degenerate island falls back to MOVE, the only non-destructive default")
    func degenerateIslandMoves() {
        let flat = (min: SIMD2<Float>(0.1, 0.5), max: SIMD2<Float>(0.9, 0.5))
        // Scale about a zero extent could collapse the island; move cannot.
        #expect(UVIslandGesture.mode(forStartingAt: SIMD2(0.5, 0.5), in: flat) == .move)
    }

    // MARK: - Transform derivation

    @Test("Move translates by exactly the drag delta")
    func moveIsTheDelta() {
        let t = UVIslandGesture.transform(
            mode: .move, from: SIMD2(0.3, 0.5), to: SIMD2(0.45, 0.42), about: centre
        )
        #expect(abs(t.translate.x - 0.15) < 1e-6)
        #expect(abs(t.translate.y + 0.08) < 1e-6)
        #expect(t.radians == 0)
        #expect(t.scale == 1)
    }

    @Test("Rotate sweeps the angle about the island centre")
    func rotateSweepsTheAngle() {
        // From due east to due north about the centre is a quarter turn counter-clockwise.
        let t = UVIslandGesture.transform(
            mode: .rotate, from: centre + SIMD2(0.1, 0), to: centre + SIMD2(0, 0.1),
            about: centre
        )
        #expect(abs(t.radians - .pi / 2) < 1e-5)
        #expect(t.translate == .zero)
        #expect(t.scale == 1)
    }

    @Test("Scale is the RATIO of distances, so it is scale-invariant")
    func scaleIsARatio() {
        let near = UVIslandGesture.transform(
            mode: .scale, from: centre + SIMD2(0.1, 0), to: centre + SIMD2(0.2, 0), about: centre
        )
        let far = UVIslandGesture.transform(
            mode: .scale, from: centre + SIMD2(0.2, 0), to: centre + SIMD2(0.4, 0), about: centre
        )
        // Doubling the distance doubles the island, whatever the absolute distances were: the same
        // finger travel must mean the same multiplication on a small island and a large one.
        #expect(abs(near.scale - 2) < 1e-5)
        #expect(abs(far.scale - 2) < 1e-5)
    }

    @Test("Scale is clamped so one stray sample cannot collapse or explode an island")
    func scaleIsClamped() {
        let collapse = UVIslandGesture.transform(
            mode: .scale, from: centre + SIMD2(0.5, 0), to: centre, about: centre
        )
        // Never zero or negative: the engine refuses those outright, and the gesture must not ask.
        #expect(collapse.scale > 0)
        #expect(collapse.scale >= 0.05)

        let explode = UVIslandGesture.transform(
            mode: .scale, from: centre + SIMD2(0.001, 0), to: centre + SIMD2(5, 0), about: centre
        )
        #expect(explode.scale <= 20)
    }

    @Test("A drag starting on the centroid yields NO rotation or scale, not a violent one")
    func degenerateLeverArmIsInert() {
        // The angle about a point you are standing on is ill-conditioned — a sub-pixel wobble
        // swings it wildly — so the gesture must decline rather than lurch.
        let rotate = UVIslandGesture.transform(
            mode: .rotate, from: centre, to: centre + SIMD2(0.2, 0.2), about: centre
        )
        #expect(rotate == UVIslandGesture.Transform())

        let scale = UVIslandGesture.transform(
            mode: .scale, from: centre, to: centre + SIMD2(0.2, 0), about: centre
        )
        #expect(scale == UVIslandGesture.Transform())
    }

    // MARK: - Canvas mapping

    @Test("Canvas points map back to UV space, undoing the v flip")
    func canvasPointsMapBack() {
        let rect = CGRect(x: 10, y: 20, width: 200, height: 200)
        // The bottom of the rect is v = 0; the top is v = 1. Getting this backwards would swap
        // the rotate and scale zones for every gesture.
        let bottom = UVLayoutPanelView.uv(at: CGPoint(x: 10, y: 220), in: rect)
        #expect(abs(bottom.x) < 1e-6)
        #expect(abs(bottom.y) < 1e-6)

        let top = UVLayoutPanelView.uv(at: CGPoint(x: 210, y: 20), in: rect)
        #expect(abs(top.x - 1) < 1e-6)
        #expect(abs(top.y - 1) < 1e-6)
    }

    @Test("Mapping a degenerate rect is safe rather than producing infinities")
    func degenerateRectIsSafe() {
        let uv = UVLayoutPanelView.uv(at: CGPoint(x: 5, y: 5), in: .zero)
        #expect(uv == .zero)
    }

    // MARK: - Ring hit-testing

    @Test("A point inside a ring selects that ring, not merely the nearest centre")
    func hitTestPrefersContainment() throws {
        let left: [SIMD2<Float>] = [
            SIMD2(0.0, 0.0), SIMD2(0.4, 0.0), SIMD2(0.4, 1.0), SIMD2(0.0, 1.0),
        ]
        let right: [SIMD2<Float>] = [
            SIMD2(0.6, 0.0), SIMD2(1.0, 0.0), SIMD2(1.0, 1.0), SIMD2(0.6, 1.0),
        ]
        let layout = UVLayoutGeometry.Layout(
            rings: [left, right], overflowCorners: 0, faceIDs: [7, 9], distortion: []
        )
        #expect(layout.ringIndex(at: SIMD2(0.1, 0.5)) == 0)
        #expect(layout.ringIndex(at: SIMD2(0.9, 0.5)) == 1)
    }

    @Test("A point in no ring falls back to the NEAREST, so a near-miss still grabs an island")
    func hitTestFallsBackToNearest() {
        let far: [SIMD2<Float>] = [
            SIMD2(0.8, 0.8), SIMD2(0.9, 0.8), SIMD2(0.9, 0.9), SIMD2(0.8, 0.9),
        ]
        let near: [SIMD2<Float>] = [
            SIMD2(0.0, 0.0), SIMD2(0.1, 0.0), SIMD2(0.1, 0.1), SIMD2(0.0, 0.1),
        ]
        let layout = UVLayoutGeometry.Layout(
            rings: [far, near], overflowCorners: 0, faceIDs: [1, 2], distortion: []
        )
        // Just outside the second ring: a drag that starts a hair off a thin island should still
        // grab it rather than silently doing nothing.
        #expect(layout.ringIndex(at: SIMD2(0.12, 0.05)) == 1)
    }

    @Test("An empty layout has no ring to hit")
    func emptyLayoutHasNoRing() {
        let layout = UVLayoutGeometry.Layout(rings: [], overflowCorners: 0, distortion: [])
        #expect(layout.ringIndex(at: SIMD2(0.5, 0.5)) == nil)
    }

    // MARK: - On-surface (UV3D) camera-as-manipulator transform (6.3b)

    @Test("The three on-surface channels map to distinct transform components")
    func onSurfaceChannelsAreDistinct() {
        // Each gesture drives ONE component, so none can be mistaken for another: pinch scales,
        // twist rotates, orbit moves.
        let pinched = UVIslandGesture.onSurfaceTransform(
            pinchScale: 1.5, rollRadians: 0, orbitDelta: .zero
        )
        #expect(pinched.scale == 1.5)
        #expect(pinched.radians == 0)
        #expect(pinched.translate == .zero)

        let twisted = UVIslandGesture.onSurfaceTransform(
            pinchScale: 1, rollRadians: 0.4, orbitDelta: .zero
        )
        #expect(twisted.radians == 0.4)
        #expect(twisted.scale == 1)
        #expect(twisted.translate == .zero)

        let orbited = UVIslandGesture.onSurfaceTransform(
            pinchScale: 1, rollRadians: 0, orbitDelta: SIMD2(0.3, -0.2)
        )
        #expect(orbited.translate.x == 0.3 * UVIslandGesture.orbitToUVGain)
        #expect(orbited.translate.y == -0.2 * UVIslandGesture.orbitToUVGain)
        #expect(orbited.scale == 1)
    }

    @Test("An untouched on-surface session yields the IDENTITY, so it journals nothing")
    func untouchedSessionIsIdentity() {
        // A session armed and committed without moving the camera must leave no undo entry —
        // `runTransformIsland` declines the identity, and this is what makes that reachable.
        #expect(
            UVIslandGesture.onSurfaceTransform(
                pinchScale: 1, rollRadians: 0, orbitDelta: .zero
            ) == UVIslandGesture.Transform()
        )
    }

    @Test("A non-positive pinch scale never reaches the engine")
    func onSurfaceScaleIsAlwaysPositive() {
        // The engine refuses a non-positive scale outright; a gesture must never be the thing that
        // asks for one, even if the camera reported something degenerate.
        for bad in [Float(0), -1, -0.0] {
            let transform = UVIslandGesture.onSurfaceTransform(
                pinchScale: bad, rollRadians: 0, orbitDelta: .zero
            )
            #expect(transform.scale > 0)
        }
    }

    @Test("Orbit delta is normalized by scene radius, so model scale does not change the feel")
    func orbitDeltaIsScaleInvariant() {
        // The same camera displacement on a model ten times larger must move the island ten times
        // LESS in UV space — i.e. the same fraction of the model equals the same UV distance.
        var small = UVIslandTransformPlan(face: 0, pivot: .zero)
        small.orbitChanged(
            displacement: SIMD3(1, 0, 0), right: SIMD3(1, 0, 0), up: SIMD3(0, 1, 0),
            sceneRadius: 1
        )
        var large = UVIslandTransformPlan(face: 0, pivot: .zero)
        large.orbitChanged(
            displacement: SIMD3(1, 0, 0), right: SIMD3(1, 0, 0), up: SIMD3(0, 1, 0),
            sceneRadius: 10
        )
        #expect(abs(small.orbitDelta.x - 1) < 1e-6)
        #expect(abs(large.orbitDelta.x - 0.1) < 1e-6)
    }

    @Test("A degenerate scene radius leaves the orbit delta alone rather than dividing by zero")
    func degenerateSceneRadiusIsSafe() {
        var plan = UVIslandTransformPlan(face: 0, pivot: .zero)
        plan.orbitChanged(
            displacement: SIMD3(5, 5, 5), right: SIMD3(1, 0, 0), up: SIMD3(0, 1, 0),
            sceneRadius: 0
        )
        #expect(plan.orbitDelta == .zero)
    }

    @Test("The on-surface tool is a CAMERA manipulator, which is why it needs no new arbitration")
    func toolIsACameraManipulator() {
        // `InputArbiter.cameraFeedsArmedTool` already blurs pen-authors/fingers-navigate for exactly
        // this class of tool, and owns that verdict — so the pinch reuses an established seam rather
        // than competing with the camera.
        #expect(RetopoTool.transformIslandUV.isCameraManipulator)
        #expect(EditorAction.transformIslandUV.tool == .transformIslandUV)
    }
}

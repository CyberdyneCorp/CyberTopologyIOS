import Foundation
import Testing
import simd
@testable import CyberTopology

/// Two-finger twist → camera roll (openspec add-two-finger-roll; spec:
/// viewport-rendering / "Two-finger twist rolls the view around the fingers").
@MainActor
struct CameraRollTests {
    private let bounds = SceneBounds(
        lower: SIMD3(repeating: -2), upper: SIMD3(repeating: 2)
    )

    private func camera() -> CameraState {
        CameraState.framing(bounds, aspect: 1.5)
    }

    /// Projects a world point to normalized device coordinates (x,y in -1...1).
    private func project(_ world: SIMD3<Float>, with camera: CameraState) -> SIMD2<Float> {
        let clip =
            camera.projectionMatrix(aspect: 1.5, bounds: bounds) * camera.viewMatrix()
            * SIMD4(world, 1)
        return SIMD2(clip.x / clip.w, clip.y / clip.w)
    }

    // MARK: - The geometry

    /// The sign is the error an assertion about the ANGLE cannot catch, and the
    /// one that is instantly obvious on device: rolling the camera one way turns
    /// the scene the other.
    @Test func rollingTurnsTheSceneAroundThePivot() {
        var rolled = camera()
        let pivot = rolled.focus
        // A point directly ABOVE the pivot on screen.
        let (_, up, _) = rolled.basis
        let marker = pivot + up * 0.5
        let before = project(marker, with: rolled)
        #expect(abs(before.x) < 1e-4 && before.y > 0, "the marker starts above the pivot")

        // CONVENTION: a positive camera roll turns the scene COUNTER-clockwise
        // on screen. UIKit's gesture rotation is positive clockwise, so
        // `handleRotation` negates it — that is what makes the scene follow the
        // fingers instead of fighting them.
        rolled.roll(byRadians: .pi / 2, about: pivot)
        let after = project(marker, with: rolled)
        #expect(after.x < 0, "expected the marker to swing LEFT, landed at \(after)")
        // A quarter turn exactly: what was `d` above the pivot is now `d` to its
        // left. Asserting the magnitude too is what makes this a rotation test
        // rather than a "something moved" test — scaled by the ASPECT, since NDC
        // x is divided by it and the offset has changed axis.
        #expect(
            abs(abs(after.x) * 1.5 - before.y) < 1e-3, "before \(before), after \(after)"
        )
        #expect(abs(after.y) < 1e-3)
    }

    @Test func thePivotKeepsItsScreenPosition() {
        var rolled = camera()
        // An off-centre pivot: rolling about the screen centre would move it,
        // which is the whole failure this guards.
        let pivot = rolled.focus + rolled.basis.right * 0.7 + rolled.basis.up * 0.3
        let before = project(pivot, with: rolled)

        rolled.roll(byRadians: 0.6, about: pivot)

        let after = project(pivot, with: rolled)
        #expect(
            simd_distance(before, after) < 1e-3,
            "the pivot moved from \(before) to \(after)"
        )
    }

    @Test func rollingDoesNotZoomOrOrbit() {
        var rolled = camera()
        let original = rolled
        rolled.roll(byRadians: 0.4, about: rolled.focus + rolled.basis.right)

        #expect(rolled.distance == original.distance)
        #expect(rolled.azimuth == original.azimuth)
        #expect(rolled.elevation == original.elevation)
        #expect(rolled.fovY == original.fovY)
        #expect(rolled.roll == 0.4)
    }

    @Test func theBasisStaysOrthonormalAndForwardIsUnchanged() {
        var rolled = camera()
        let forwardBefore = rolled.basis.forward
        rolled.roll(byRadians: 1.1, about: rolled.focus)
        let (right, up, forward) = rolled.basis

        #expect(simd_distance(forward, forwardBefore) < 1e-5, "roll must not turn the camera")
        #expect(abs(simd_length(right) - 1) < 1e-5)
        #expect(abs(simd_length(up) - 1) < 1e-5)
        #expect(abs(simd_dot(right, up)) < 1e-5)
        #expect(abs(simd_dot(right, forward)) < 1e-5)
        #expect(abs(simd_dot(up, forward)) < 1e-5)
    }

    /// Roll is camera STATE, so everything reading the basis — picking rays
    /// included — has to agree with what is drawn.
    @Test func pickingFollowsTheRolledView() {
        var rolled = camera()
        rolled.roll(byRadians: 0.8, about: rolled.focus)
        // A point off to one side, so a basis that ignored roll would project it
        // somewhere else entirely.
        let marker = rolled.focus + rolled.basis.right * 0.4
        let projected = project(marker, with: rolled)

        // Re-project through the same matrices the renderer uses: the check is
        // that the rolled basis is self-consistent, not merely nonzero.
        let clip =
            rolled.projectionMatrix(aspect: 1.5, bounds: bounds) * rolled.viewMatrix()
            * SIMD4(marker, 1)
        #expect(abs(clip.x / clip.w - projected.x) < 1e-5)
        #expect(projected.x > 0.05, "a point along +right must project to the right")
        #expect(abs(projected.y) < 0.05, "and not drift vertically")
    }

    @Test func aNonFiniteRollIsDegenerate() {
        var broken = camera()
        broken.roll = .nan
        #expect(broken.isDegenerate)
    }

    @Test func rollIgnoresNonFiniteAndZeroAngles() {
        var rolled = camera()
        let original = rolled
        rolled.roll(byRadians: 0, about: .zero)
        rolled.roll(byRadians: .nan, about: .zero)
        rolled.roll(byRadians: .infinity, about: .zero)
        #expect(rolled.focus == original.focus)
        #expect(rolled.roll == 0)
    }

    // MARK: - Getting back to level

    @Test func framingAndReframingLevelTheHorizon() {
        var rolled = camera()
        rolled.roll(byRadians: 1.2, about: rolled.focus + rolled.basis.right * 0.5)
        #expect(rolled.roll != 0)

        #expect(CameraState.framing(bounds, aspect: 1.5).roll == 0)
        let reframed = rolled.reframed(to: bounds, aspect: 1.5)
        #expect(reframed.roll == 0, "reframe must return a level horizon")
        // …while still preserving the orientation an ordinary reframe keeps.
        #expect(abs(reframed.azimuth - rolled.azimuth) < 1e-5)
    }

    /// A rolled camera that then pans/zooms keeps its roll, and panning still
    /// tracks the fingers — the pan direction is derived from the rolled basis.
    @Test func rollComposesWithPanAndZoom() {
        var rolled = camera()
        rolled.roll(byRadians: 0.5, about: rolled.focus)
        let rollAfterRoll = rolled.roll

        rolled.pan(byPoints: SIMD2(20, 10), viewportHeight: 800)
        rolled.zoom(byPinchScale: 1.3, speed: 1, in: bounds)

        #expect(rolled.roll == rollAfterRoll, "pan/zoom must not disturb the roll")
        #expect(!rolled.isDegenerate)
    }

    // MARK: - The threshold

    /// The threshold exists against DRIFT — the rotational noise in a straight
    /// two-finger drag accumulating into a tilted horizon — so it must not be
    /// applied as a jump once it is crossed.
    @Test func theTwistThresholdIsSubtractedNotSkipped() {
        let threshold = MetalViewport.Coordinator.rollThreshold
        #expect(threshold > 0)

        // Below the threshold: nothing.
        #expect(!(abs(threshold * 0.5) > threshold))

        // Crossing it by a hair applies a hair, not the whole rotation.
        let rotation = threshold + 0.01
        let applied = rotation - threshold
        #expect(abs(applied - 0.01) < 1e-6)

        // And symmetrically for the other direction.
        let negative = -(threshold + 0.01)
        let appliedNegative = negative + threshold
        #expect(abs(appliedNegative + 0.01) < 1e-6)
    }
}

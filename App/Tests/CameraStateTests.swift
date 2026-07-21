import Testing
import simd
@testable import CyberTopology

// Pure camera-math tests (no Metal): spec viewport-rendering / "Robust
// camera system".

struct SceneBoundsTests {
    @Test func boundsFromInterleavedPositions() throws {
        let bounds = try #require(SceneBounds(positions: [0, 0, 0, 1, 2, 3, -1, 0.5, 2]))
        #expect(bounds.lower == SIMD3(-1, 0, 0))
        #expect(bounds.upper == SIMD3(1, 2, 3))
        #expect(bounds.center == SIMD3(0, 1, 1.5))
        #expect(abs(bounds.radius - length(SIMD3<Float>(2, 2, 3)) * 0.5) < 1e-5)
    }

    @Test func emptyOrMalformedPositionsYieldNil() {
        #expect(SceneBounds(positions: []) == nil)
        #expect(SceneBounds(positions: [1, 2]) == nil)
        #expect(SceneBounds(positions: [1, 2, 3, 4]) == nil)
    }

    @Test func radiusIsFlooredForDegenerateGeometry() throws {
        let point = try #require(SceneBounds(positions: [5, 5, 5]))
        #expect(point.radius == SceneBounds.minimumRadius)
    }
}

struct CameraStateTests {
    /// True when every corner of `bounds` lands inside the clip volume.
    private func frustumContains(
        _ bounds: SceneBounds, camera: CameraState, aspect: Float
    ) -> Bool {
        let mvp = camera.projectionMatrix(aspect: aspect, bounds: bounds) * camera.viewMatrix()
        for ix in 0...1 {
            for iy in 0...1 {
                for iz in 0...1 {
                    let corner = SIMD3(
                        ix == 0 ? bounds.lower.x : bounds.upper.x,
                        iy == 0 ? bounds.lower.y : bounds.upper.y,
                        iz == 0 ? bounds.lower.z : bounds.upper.z
                    )
                    let clip = mvp * SIMD4(corner, 1)
                    guard clip.w > 0,
                        abs(clip.x) <= clip.w, abs(clip.y) <= clip.w,
                        clip.z >= 0, clip.z <= clip.w
                    else { return false }
                }
            }
        }
        return true
    }

    private func cube(halfExtent: Float) -> SceneBounds {
        SceneBounds(
            lower: SIMD3(repeating: -halfExtent), upper: SIMD3(repeating: halfExtent)
        )
    }

    // MARK: - Framing

    @Test func framingContainsWholeSceneInLandscape() {
        let bounds = cube(halfExtent: 1)
        let camera = CameraState.framing(bounds, aspect: 1.5)
        #expect(camera.focus == bounds.center)
        #expect(frustumContains(bounds, camera: camera, aspect: 1.5))
    }

    @Test func framingContainsWholeSceneInPortrait() {
        let bounds = cube(halfExtent: 1)
        let camera = CameraState.framing(bounds, aspect: 0.6)
        #expect(frustumContains(bounds, camera: camera, aspect: 0.6))
    }

    @Test func framingSurvivesInvalidAspect() {
        let camera = CameraState.framing(cube(halfExtent: 1), aspect: .nan)
        #expect(!camera.isDegenerate)
    }

    // MARK: - Scale-adaptive clipping (spec scenario)

    @Test func clipPlanesFitTinyScene() {
        // 2 mm object, meters as world unit — no near-plane clipping and no
        // pre-scaling allowed (spec: "Scale-adaptive clipping").
        let bounds = cube(halfExtent: 0.001)
        let camera = CameraState.framing(bounds, aspect: 1.4)
        let (near, far) = camera.clipPlanes(for: bounds)
        #expect(near > 0)
        #expect(near <= camera.distance - bounds.radius)
        #expect(far >= camera.distance + bounds.radius)
        #expect(far / near < 1e6)
        #expect(frustumContains(bounds, camera: camera, aspect: 1.4))
    }

    @Test func clipPlanesFitHugeScene() {
        // 200 m object under the same math.
        let bounds = cube(halfExtent: 100)
        let camera = CameraState.framing(bounds, aspect: 1.4)
        let (near, far) = camera.clipPlanes(for: bounds)
        #expect(near > 0)
        #expect(near <= camera.distance - bounds.radius)
        #expect(far >= camera.distance + bounds.radius)
        #expect(far / near < 1e6)
        #expect(frustumContains(bounds, camera: camera, aspect: 1.4))
    }

    @Test func clipPlanesStayValidWithCameraInsideScene() {
        let bounds = cube(halfExtent: 1)
        var camera = CameraState.framing(bounds, aspect: 1)
        camera.distance = bounds.radius * 0.01  // deep inside the mesh
        let (near, far) = camera.clipPlanes(for: bounds)
        #expect(near > 0)
        #expect(far > near)
    }

    @Test func clipPlanesToleratesNonFiniteDistance() {
        let bounds = cube(halfExtent: 1)
        var camera = CameraState.framing(bounds, aspect: 1)
        camera.distance = .nan
        let (near, far) = camera.clipPlanes(for: bounds)
        #expect(near > 0 && far > near)
    }

    /// Regression: clip planes must track the camera-to-scene distance, not
    /// the orbit (focus) distance. Large two-finger pans move the focus far
    /// off the bounds center; the far plane must still clear every possible
    /// mesh point or the mesh vanishes (spec: "Scale-adaptive clipping").
    @Test func clipPlanesCoverSceneAfterLargePans() {
        let bounds = cube(halfExtent: 1)
        var camera = CameraState.framing(bounds, aspect: 1.4)
        for _ in 0..<3 {
            camera.pan(byPoints: SIMD2(800, 0), viewportHeight: 800)
        }
        // The focus is now well outside the scene bounds…
        #expect(length(camera.focus - bounds.center) > 4 * bounds.radius)
        let (near, far) = camera.clipPlanes(for: bounds)
        #expect(near > 0)
        // …and the far plane still clears the whole bounding sphere.
        #expect(far >= length(camera.position - bounds.center) + bounds.radius)
    }

    /// Same regression at view-depth level: after pans plus an orbit (which
    /// rotates the panned-away scene toward the view axis), every bounds
    /// corner must stay within the far plane in either orbit direction.
    @Test func clipPlanesCoverSceneDepthAfterPanAndOrbit() {
        let bounds = cube(halfExtent: 1)
        for orbitPoints in [Float(200), -200, 400, -400] {
            var camera = CameraState.framing(bounds, aspect: 1.4)
            for _ in 0..<3 {
                camera.pan(byPoints: SIMD2(0, 800), viewportHeight: 800)
            }
            camera.orbit(byPoints: SIMD2(orbitPoints, 0), speed: 1)
            let (near, far) = camera.clipPlanes(for: bounds)
            #expect(near > 0)
            let view = camera.viewMatrix()
            for ix in 0...1 {
                for iy in 0...1 {
                    for iz in 0...1 {
                        let corner = SIMD3(
                            ix == 0 ? bounds.lower.x : bounds.upper.x,
                            iy == 0 ? bounds.lower.y : bounds.upper.y,
                            iz == 0 ? bounds.lower.z : bounds.upper.z
                        )
                        let viewSpace = view * SIMD4(corner, 1)
                        #expect(-viewSpace.z <= far)
                    }
                }
            }
        }
    }

    // MARK: - Interaction

    @Test func orbitFollowsSpeedAndClampsElevation() {
        var camera = CameraState()
        let before = camera
        camera.orbit(byPoints: SIMD2(10, 5), speed: 1)
        #expect(abs((before.azimuth - camera.azimuth) - 10 * CameraState.orbitRadiansPerPoint) < 1e-5)
        #expect(abs((camera.elevation - before.elevation) - 5 * CameraState.orbitRadiansPerPoint) < 1e-5)

        var fast = CameraState()
        fast.orbit(byPoints: SIMD2(10, 0), speed: 2)
        #expect(abs((CameraState().azimuth - fast.azimuth) - 20 * CameraState.orbitRadiansPerPoint) < 1e-5)

        camera.orbit(byPoints: SIMD2(0, 100_000), speed: 1)
        #expect(camera.elevation == CameraState.elevationLimit)
        camera.orbit(byPoints: SIMD2(0, -1_000_000), speed: 1)
        #expect(camera.elevation == -CameraState.elevationLimit)
    }

    @Test func zoomIsClampedAndSpeedScaled() {
        let bounds = cube(halfExtent: 1)
        var camera = CameraState.framing(bounds, aspect: 1)
        let start = camera.distance
        camera.zoom(byPinchScale: 2, speed: 1, in: bounds)
        #expect(abs(camera.distance - start / 2) < 1e-5)

        var fast = CameraState.framing(bounds, aspect: 1)
        fast.zoom(byPinchScale: 2, speed: 2, in: bounds)
        #expect(abs(fast.distance - start / 4) < 1e-4)

        camera.zoom(byPinchScale: 1e10, speed: 1, in: bounds)
        #expect(camera.distance == bounds.radius * CameraState.minDistanceFactor)
        camera.zoom(byPinchScale: 1e-10, speed: 1, in: bounds)
        #expect(camera.distance == bounds.radius * CameraState.maxDistanceFactor)
    }

    @Test func zoomIgnoresNonPositiveScale() {
        let bounds = cube(halfExtent: 1)
        var camera = CameraState.framing(bounds, aspect: 1)
        let before = camera
        camera.zoom(byPinchScale: 0, speed: 1, in: bounds)
        camera.zoom(byPinchScale: -3, speed: 1, in: bounds)
        #expect(camera == before)
    }

    @Test func panMovesFocusInViewPlane() {
        var camera = CameraState.framing(cube(halfExtent: 1), aspect: 1)
        let before = camera
        camera.pan(byPoints: SIMD2(120, -40), viewportHeight: 800)
        let motion = camera.focus - before.focus
        #expect(length(motion) > 0)
        // The focus moves perpendicular to the viewing direction.
        #expect(abs(dot(normalize(motion), before.basis.forward)) < 1e-4)
        // Camera orientation and distance are untouched.
        #expect(camera.distance == before.distance)
        #expect(camera.azimuth == before.azimuth)
    }

    @Test func panIgnoresZeroViewportHeight() {
        var camera = CameraState()
        let before = camera
        camera.pan(byPoints: SIMD2(10, 10), viewportHeight: 0)
        #expect(camera == before)
    }

    // MARK: - Camera rescue (spec scenario)

    @Test func rescueFromInsideMeshReframesOutside() {
        let bounds = cube(halfExtent: 1)
        // Camera collapsed inside the mesh.
        let inside = CameraState(focus: bounds.center, distance: bounds.radius * 0.01)
        let rescued = inside.reframed(to: bounds, aspect: 1.33)
        #expect(length(rescued.position - bounds.center) > bounds.radius)
        #expect(frustumContains(bounds, camera: rescued, aspect: 1.33))
    }

    @Test func rescueFromDegeneratePoseRestoresValidFraming() {
        let bounds = cube(halfExtent: 1)
        var camera = CameraState()
        camera.azimuth = .nan
        camera.distance = 0
        camera.focus = SIMD3(.infinity, 0, 0)
        #expect(camera.isDegenerate)

        let rescued = camera.reframed(to: bounds, aspect: 1)
        #expect(!rescued.isDegenerate)
        #expect(rescued.azimuth == CameraState.defaultAzimuth)
        #expect(frustumContains(bounds, camera: rescued, aspect: 1))
        // The resulting matrices are finite.
        let view = rescued.viewMatrix()
        for column in [view.columns.0, view.columns.1, view.columns.2, view.columns.3] {
            #expect(column.x.isFinite && column.y.isFinite && column.z.isFinite && column.w.isFinite)
        }
    }

    @Test func rescuePreservesFiniteOrientation() {
        let bounds = cube(halfExtent: 1)
        var camera = CameraState.framing(bounds, aspect: 1)
        camera.orbit(byPoints: SIMD2(37, -12), speed: 1)
        let rescued = camera.reframed(to: bounds, aspect: 1)
        #expect(rescued.azimuth == camera.azimuth)
        #expect(rescued.elevation == camera.elevation)
        #expect(rescued.focus == bounds.center)
    }

    // MARK: - Matrices

    @Test func viewMatrixMapsFocusAndEyeCorrectly() {
        let camera = CameraState(
            focus: SIMD3(1, 2, 3), distance: 5, azimuth: 0.9, elevation: -0.2
        )
        let view = camera.viewMatrix()
        let eye = view * SIMD4(camera.position, 1)
        #expect(length(SIMD3(eye.x, eye.y, eye.z)) < 1e-4)
        let focus = view * SIMD4(camera.focus, 1)
        #expect(abs(focus.x) < 1e-4)
        #expect(abs(focus.y) < 1e-4)
        #expect(abs(focus.z + camera.distance) < 1e-4)
    }

    @Test func projectionMapsClipRangeToZeroOne() {
        let bounds = cube(halfExtent: 1)
        let camera = CameraState.framing(bounds, aspect: 1)
        let (near, far) = camera.clipPlanes(for: bounds)
        let projection = camera.projectionMatrix(aspect: 1, bounds: bounds)
        let onNear = projection * SIMD4<Float>(0, 0, -near, 1)
        let onFar = projection * SIMD4<Float>(0, 0, -far, 1)
        #expect(abs(onNear.z / onNear.w) < 1e-4)
        #expect(abs(onFar.z / onFar.w - 1) < 1e-4)
    }

    // MARK: - Animation

    @Test func interpolateHitsExactEndpoints() {
        let from = CameraState(focus: SIMD3(0, 0, 0), distance: 1, azimuth: 0, elevation: 0)
        let to = CameraState(focus: SIMD3(1, 2, 3), distance: 9, azimuth: 1, elevation: 0.5)
        #expect(CameraState.interpolate(from: from, to: to, progress: 0) == from)
        #expect(CameraState.interpolate(from: from, to: to, progress: 1) == to)
        let mid = CameraState.interpolate(from: from, to: to, progress: 0.5)
        #expect(abs(mid.distance - 5) < 1e-5)
    }

    @Test func animationEasesAndFinishes() {
        let from = CameraState(distance: 1)
        let to = CameraState(distance: 3)
        let animation = CameraAnimation(from: from, to: to, startTime: 10, duration: 0.5)
        let early = animation.value(at: 10)
        #expect(early.camera == from)
        #expect(!early.finished)
        let mid = animation.value(at: 10.25)
        #expect(mid.camera.distance > from.distance && mid.camera.distance < to.distance)
        let end = animation.value(at: 11)
        #expect(end.camera == to)
        #expect(end.finished)
    }

    @Test func animationSnapsWhenStartPoseIsDegenerate() {
        var from = CameraState()
        from.distance = .nan
        let to = CameraState(distance: 2)
        let animation = CameraAnimation(from: from, to: to, startTime: 0, duration: 0.5)
        let result = animation.value(at: 0.1)
        #expect(result.camera == to)
        #expect(result.finished)
    }
}

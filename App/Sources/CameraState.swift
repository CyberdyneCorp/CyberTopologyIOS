import simd

// Camera math for the Metal viewport (spec: viewport-rendering / "Robust
// camera system"). Pure value types: no Metal, no UIKit — fully unit-testable.

/// Axis-aligned bounding box of the renderable scene, used for frame-to-fit
/// and scale-adaptive clip planes.
struct SceneBounds: Equatable {
    var lower: SIMD3<Float>
    var upper: SIMD3<Float>

    /// Radius floor so a degenerate scene (single point, flat axis) still
    /// yields usable framing distances and positive clip planes.
    static let minimumRadius: Float = 1e-6

    /// Fallback bounds when no geometry is loaded.
    static let unit = SceneBounds(lower: SIMD3(repeating: -0.5), upper: SIMD3(repeating: 0.5))

    init(lower: SIMD3<Float>, upper: SIMD3<Float>) {
        self.lower = lower
        self.upper = upper
    }

    /// Bounds of an x,y,z-interleaved position array; `nil` when the array
    /// is empty or not a multiple of 3.
    init?(positions: UnsafeBufferPointer<Float>) {
        guard !positions.isEmpty, positions.count.isMultiple(of: 3) else { return nil }
        var lower = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var upper = -lower
        for base in stride(from: 0, to: positions.count, by: 3) {
            let p = SIMD3(positions[base], positions[base + 1], positions[base + 2])
            lower = simd.min(lower, p)
            upper = simd.max(upper, p)
        }
        self.init(lower: lower, upper: upper)
    }

    init?(positions: [Float]) {
        guard let bounds = positions.withUnsafeBufferPointer(SceneBounds.init(positions:)) else {
            return nil
        }
        self = bounds
    }

    var center: SIMD3<Float> { (lower + upper) * 0.5 }

    /// Half-diagonal of the box (bounding-sphere radius), floored at
    /// `minimumRadius`.
    var radius: Float { max(length(upper - lower) * 0.5, Self.minimumRadius) }
}

/// Turntable-orbit camera around a focus point (y-up, right-handed).
///
/// All mutating operations keep the state valid (clamped elevation, positive
/// finite distance); `reframed(to:aspect:)` is the camera-rescue primitive
/// that recovers from *any* pose, including degenerate ones.
struct CameraState: Equatable {
    static let defaultFovY: Float = 50 * .pi / 180
    /// Elevation clamp (±~85°) keeps the view axis away from the world up
    /// vector so the look-at basis never degenerates.
    static let elevationLimit: Float = .pi / 2 - 0.09
    /// Default 3/4 view used for initial framing and degenerate rescue.
    static let defaultAzimuth: Float = 0.7
    static let defaultElevation: Float = 0.4
    /// Orbit sensitivity at speed 1 (radians per screen point).
    static let orbitRadiansPerPoint: Float = 0.008
    /// Frame-to-fit margin so the fitted object does not touch the edges.
    static let framingMargin: Float = 1.15
    /// Smallest near/far ratio the depth buffer is allowed to be squeezed to.
    /// 1e-3 leaves ~3 decades of depth resolution across the scene; the 1e-5
    /// this replaced left the front and back of a fitted model indistinguishable.
    static let minNearFarRatio: Float = 1e-3

    /// Zoom clamp relative to scene radius: deliberately allows diving well
    /// inside the mesh (rescue always recovers) but never to a degenerate
    /// zero/negative distance.
    static let minDistanceFactor: Float = 2e-3
    static let maxDistanceFactor: Float = 500

    var focus: SIMD3<Float>
    var distance: Float
    var azimuth: Float
    var elevation: Float
    var fovY: Float
    /// Roll about the view direction, in radians (openspec add-two-finger-roll).
    ///
    /// Camera STATE rather than a display transform: `basis` is what the picking
    /// rays, the pan direction and the camera-as-manipulator tools all read, and
    /// a roll applied only where the image is produced would leave every one of
    /// them computing against an up vector the artist can see is wrong.
    var roll: Float

    init(
        focus: SIMD3<Float> = .zero,
        distance: Float = 1,
        azimuth: Float = CameraState.defaultAzimuth,
        elevation: Float = CameraState.defaultElevation,
        fovY: Float = CameraState.defaultFovY,
        roll: Float = 0
    ) {
        self.focus = focus
        self.distance = distance
        self.azimuth = azimuth
        self.elevation = elevation
        self.fovY = fovY
        self.roll = roll
    }

    // MARK: - Derived geometry

    /// Unit vector from focus toward the camera.
    static func direction(azimuth: Float, elevation: Float) -> SIMD3<Float> {
        SIMD3(
            cos(elevation) * sin(azimuth),
            sin(elevation),
            cos(elevation) * cos(azimuth)
        )
    }

    var position: SIMD3<Float> {
        focus + distance * Self.direction(azimuth: azimuth, elevation: elevation)
    }

    /// View-space basis in world coordinates (right, up, forward), including
    /// `roll` — everything downstream of this agrees with what is on screen.
    var basis: (right: SIMD3<Float>, up: SIMD3<Float>, forward: SIMD3<Float>) {
        let forward = normalize(focus - position)
        let level = normalize(cross(forward, SIMD3(0, 1, 0)))
        let levelUp = cross(level, forward)
        guard roll != 0, roll.isFinite else { return (level, levelUp, forward) }
        let c = cos(roll)
        let s = sin(roll)
        // Rodrigues about `forward`, the SAME sense `roll(byRadians:about:)`
        // rotates the focus in. The two must agree or they do not cancel, and
        // the pivot slides across the screen as the view rolls (`forward ×
        // right = -up`, which is where the signs below come from).
        return (level * c - levelUp * s, levelUp * c + level * s, forward)
    }

    /// True when any component is non-finite or the distance collapsed —
    /// the poses camera-rescue must recover from.
    var isDegenerate: Bool {
        let scalars = [focus.x, focus.y, focus.z, distance, azimuth, elevation, fovY, roll]
        return scalars.contains { !$0.isFinite } || distance <= 0
    }

    // MARK: - Interaction

    /// One-finger drag: turntable orbit. `speed` is the user setting (1 =
    /// default sensitivity).
    mutating func orbit(byPoints delta: SIMD2<Float>, speed: Float) {
        let factor = Self.orbitRadiansPerPoint * speed
        azimuth -= delta.x * factor
        elevation += delta.y * factor
        elevation = simd_clamp(elevation, -Self.elevationLimit, Self.elevationLimit)
    }

    /// Pinch: exponential zoom toward the focus point, clamped relative to
    /// the scene radius so distance never collapses or explodes.
    mutating func zoom(byPinchScale scale: Float, speed: Float, in bounds: SceneBounds) {
        guard scale > 0 else { return }
        let radius = bounds.radius
        distance = simd_clamp(
            distance / pow(scale, speed),
            radius * Self.minDistanceFactor,
            radius * Self.maxDistanceFactor
        )
    }

    /// Two-finger drag: pans the focus point in the view plane, scaled so
    /// on-screen content tracks the fingers 1:1 at the focus depth.
    mutating func pan(byPoints delta: SIMD2<Float>, viewportHeight: Float) {
        guard viewportHeight > 0 else { return }
        let worldPerPoint = 2 * distance * tan(fovY * 0.5) / viewportHeight
        let (right, up, _) = basis
        focus += (-delta.x * right + delta.y * up) * worldPerPoint
    }

    /// Two-finger twist: rolls the view about the axis through `pivot` parallel
    /// to the view direction, so the pivot keeps its screen position.
    ///
    /// SIGN: a positive angle turns the scene COUNTER-clockwise on screen.
    /// UIKit's gesture rotation is positive clockwise, so `handleRotation`
    /// negates it — that is what makes the scene follow the fingers rather than
    /// fight them, and it is invisible to any assertion about the angle alone
    /// (`CameraRollTests.rollingTurnsTheSceneAroundThePivot` pins it by
    /// projecting a marker and checking which way it travels).
    ///
    /// Rolling about the camera's OWN axis would spin the scene about the screen
    /// centre and slide the work out from under the fingers — the opposite of
    /// what the gesture promises. Rotating the focus about the pivot's axis
    /// leaves `distance`, `azimuth` and `elevation` untouched, and the eye
    /// follows for free: the eye-to-focus offset lies ALONG the rotation axis,
    /// so the rotation does not move it.
    mutating func roll(byRadians angle: Float, about pivot: SIMD3<Float>) {
        guard angle.isFinite, angle != 0 else { return }
        let axis = basis.forward
        let offset = focus - pivot
        let c = cos(angle)
        let s = sin(angle)
        // Rodrigues about a unit axis.
        let rotated =
            offset * c + cross(axis, offset) * s + axis * dot(axis, offset) * (1 - c)
        focus = pivot + rotated
        roll += angle
    }

    // MARK: - Framing / rescue

    /// Distance at which a sphere of `radius` exactly fits the frustum
    /// (limited by the narrower field-of-view axis), padded by the margin.
    static func fitDistance(radius: Float, fovY: Float, aspect: Float) -> Float {
        let safeAspect = aspect.isFinite && aspect > 0 ? aspect : 1
        let fovX = 2 * atan(tan(fovY * 0.5) * safeAspect)
        let halfFov = min(fovY, fovX) * 0.5
        return radius / tan(halfFov) * framingMargin
    }

    /// Frame-to-fit camera for `bounds` at the default 3/4 orientation.
    static func framing(_ bounds: SceneBounds, aspect: Float) -> CameraState {
        CameraState(
            focus: bounds.center,
            distance: fitDistance(radius: bounds.radius, fovY: defaultFovY, aspect: aspect)
        )
    }

    /// Camera rescue (double-tap reframe): always returns a valid framing of
    /// `bounds`, regardless of the current pose — inside the mesh, collapsed
    /// distance, or non-finite state. Orientation is preserved when finite so
    /// an ordinary reframe does not snap the view around.
    func reframed(to bounds: SceneBounds, aspect: Float) -> CameraState {
        var result = Self.framing(bounds, aspect: aspect)
        if azimuth.isFinite && elevation.isFinite {
            result.azimuth = azimuth
            result.elevation = simd_clamp(
                elevation, -Self.elevationLimit, Self.elevationLimit
            )
        }
        return result
    }

    // MARK: - Clip planes

    /// Scale-adaptive near/far planes (spec: "Scale-adaptive clipping"): a
    /// 2 mm and a 200 m scene must both render without clipping. Planes are
    /// derived from the camera-to-**bounds-center** distance and scene
    /// radius — not the orbit (focus) distance: two-finger pans move the
    /// focus away from the scene, and planes based on the focus distance
    /// alone can put the entire mesh beyond the far plane after a few pans
    /// plus an orbit. The near plane is floored at a fixed fraction of the
    /// far plane so the depth ratio stays bounded (depth32 precision) even
    /// with the camera inside the scene.
    func clipPlanes(for bounds: SceneBounds) -> (near: Float, far: Float) {
        let radius = bounds.radius
        let centerDistance = length(position - bounds.center)
        let safeDistance = centerDistance.isFinite ? centerDistance : radius * 3
        let far = safeDistance + 4 * radius
        // Floored so `far/near` stays bounded. The old floor (`far * 1e-5`)
        // allowed a ratio of 100,000, and it took over at exactly the pose that
        // matters: framed to fit, `safeDistance ≈ 2 * radius`, so `d - 2r ≈ 0`.
        // The whole scene then occupied 4e-5 of the depth range — measured — and
        // no depth test, biased or not, can separate a model's front from its
        // back in that state (openspec fix-target-occlusion).
        let near = max(safeDistance - 2 * radius, far * Self.minNearFarRatio)
        return (near, far)
    }

    // MARK: - Matrices

    /// World → view (right-handed look-at from `position` toward `focus`).
    func viewMatrix() -> simd_float4x4 {
        let eye = position
        let (right, up, forward) = basis
        return simd_float4x4(columns: (
            SIMD4(right.x, up.x, -forward.x, 0),
            SIMD4(right.y, up.y, -forward.y, 0),
            SIMD4(right.z, up.z, -forward.z, 0),
            SIMD4(-dot(right, eye), -dot(up, eye), dot(forward, eye), 1)
        ))
    }

    /// View → Metal clip space (z in [0, 1]), with scale-adaptive planes.
    func projectionMatrix(aspect: Float, bounds: SceneBounds) -> simd_float4x4 {
        let safeAspect = aspect.isFinite && aspect > 0 ? aspect : 1
        let (near, far) = clipPlanes(for: bounds)
        let yScale = 1 / tan(fovY * 0.5)
        let zScale = far / (near - far)
        return simd_float4x4(columns: (
            SIMD4(yScale / safeAspect, 0, 0, 0),
            SIMD4(0, yScale, 0, 0),
            SIMD4(0, 0, zScale, -1),
            SIMD4(0, 0, near * zScale, 0)
        ))
    }

    /// The NDC-depth bias equivalent to pulling a surface `offset` world units
    /// toward the camera, measured at the FOCUS depth — what the artist is
    /// looking at, and where a surface-snapped overlay actually sits.
    ///
    /// This is the whole reason the occlusion allowance is expressed in scene
    /// units and converted here rather than stored as an NDC number: NDC depth
    /// is nonlinear and its scale depends entirely on the near and far planes,
    /// so one fixed number cannot mean the same thing on two scenes. Measured on
    /// a fitted unit-radius model, an allowance of 0.002 NDC was fifty times the
    /// model's ENTIRE depth range.
    func depthBias(forWorldOffset offset: Float, bounds: SceneBounds) -> Float {
        guard offset.isFinite, offset > 0 else { return 0 }
        let (near, far) = clipPlanes(for: bounds)
        guard far > near, near > 0 else { return 0 }
        // NDC depth of a point `t` in front of the camera, from the same
        // projection `projectionMatrix` builds.
        func depth(_ t: Float) -> Float {
            let zScale = far / (near - far)
            return (zScale * -t + near * zScale) / t
        }
        let t = max(distance, near * 2)
        let pulled = max(t - offset, near * 1.001)
        return abs(depth(t) - depth(pulled))
    }

    // MARK: - Animation support

    /// Linear pose interpolation (endpoints exact); used by the reframe
    /// animation.
    static func interpolate(from: CameraState, to: CameraState, progress: Float) -> CameraState {
        let t = simd_clamp(progress, 0, 1)
        return CameraState(
            focus: simd_mix(from.focus, to.focus, SIMD3(repeating: t)),
            distance: simd_mix(from.distance, to.distance, t),
            azimuth: simd_mix(from.azimuth, to.azimuth, t),
            elevation: simd_mix(from.elevation, to.elevation, t),
            fovY: simd_mix(from.fovY, to.fovY, t)
        )
    }
}

/// Timed reframe animation (double-tap): eases the camera from one pose to
/// another. Pure value type so the easing math is unit-testable without a
/// display link.
struct CameraAnimation: Equatable {
    var from: CameraState
    var to: CameraState
    var startTime: Double
    var duration: Double

    /// Camera pose at `time`, and whether the animation has finished.
    /// A degenerate `from` pose snaps straight to the target (interpolating
    /// through NaN would poison every frame of the animation).
    func value(at time: Double) -> (camera: CameraState, finished: Bool) {
        guard duration > 0, !from.isDegenerate else { return (to, true) }
        let progress = (time - startTime) / duration
        if progress >= 1 { return (to, true) }
        let clamped = Float(max(progress, 0))
        // Smoothstep easing.
        let eased = clamped * clamped * (3 - 2 * clamped)
        return (CameraState.interpolate(from: from, to: to, progress: eased), false)
    }
}

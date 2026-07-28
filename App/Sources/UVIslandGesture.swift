import CoreGraphics
import Foundation
import simd

/// The 2D island grammar (openspec add-uv-island-editing, 6.3; spec: uv-workflow).
///
/// "In UV2D, Tweak SHALL support the island grammar (stroke on upper part → rotate, lower →
/// scale, middle → move)." The stroke's STARTING position inside the island decides which
/// transform it drives — the same shape as the 3D grammar, where what a stroke means comes from
/// where it began rather than from a mode the artist has to select first.
///
/// Pure, so it is testable without a view, a GPU or a gesture recognizer: the panel is a SwiftUI
/// `Canvas` precisely so this stays ordinary arithmetic.
enum UVIslandGesture {

    /// What a drag starting at a given point does.
    enum Mode: String, Equatable, CaseIterable {
        case rotate
        case scale
        case move
    }

    /// Vertical thirds of the island's bounding box.
    ///
    /// Thirds rather than a centre disc: the box is the only thing the artist can see, so the
    /// zones have to be readable off it. A radial split would put "scale" in a ring whose width
    /// depends on the island's aspect, which is not something anyone can aim at.
    ///
    /// Coordinates are UV space (v UP), so "upper" means HIGH v. The panel flips v for drawing;
    /// classifying in view space instead would silently swap rotate and scale.
    static func mode(forStartingAt point: SIMD2<Float>, in box: (min: SIMD2<Float>, max: SIMD2<Float>)) -> Mode {
        let height = box.max.y - box.min.y
        guard height > 0 else {
            // A degenerate island has no upper or lower third to speak of. Move is the safe
            // default: it cannot destroy a parameterization the way a scale about a zero extent
            // could.
            return .move
        }
        let t = (point.y - box.min.y) / height
        if t >= 2.0 / 3.0 { return .rotate }
        if t <= 1.0 / 3.0 { return .scale }
        return .move
    }

    /// The transform a drag produces, given its mode and the island's UV centre.
    ///
    /// Returned as the same triple `Mesh.transformIsland` takes, so there is exactly one place
    /// that decides how a drag becomes a transform.
    struct Transform: Equatable {
        var translate: SIMD2<Float> = .zero
        var radians: Float = 0
        var scale: Float = 1
    }

    /// Minimum radius, in UV units, before a rotation or scale is derived.
    ///
    /// A drag that starts almost exactly on the centroid has an ill-conditioned angle — a
    /// sub-pixel wobble swings it wildly — so below this the gesture yields no rotation rather
    /// than a violent one.
    static let minimumLeverArm: Float = 1e-3

    /// UV units the island moves per full screen-width of camera orbit, for the on-surface
    /// (UV3D) transform.
    ///
    /// One UV unit per screen traverse: the artist drags across the viewport and the island crosses
    /// the atlas. A larger gain would make the island uncontrollable at cage scale; a smaller one
    /// would need several drags to cross the square.
    static let orbitToUVGain: Float = 1.0

    /// The transform an ON-SURFACE (UV3D) camera-as-manipulator gesture produces.
    ///
    /// The camera is the input device here — that is the established camera-as-manipulator pattern
    /// (`InputArbiter.cameraFeedsArmedTool`), and it is why this needs no new input arbitration:
    /// while a session is armed, camera motion BOTH moves the camera and drives the tool, and the
    /// arbiter owns that verdict.
    ///
    /// The three channels are deliberately distinct gestures rather than one overloaded drag, so
    /// none of them can be mistaken for another:
    ///   * pinch  (camera distance)  -> SCALE, via the same `PlacementMath.pinchScale` every other
    ///     camera tool uses, so a pinch means the same thing across tools.
    ///   * two-finger rotate (roll)  -> ROTATION.
    ///   * orbit (screen-space drag) -> TRANSLATION.
    static func onSurfaceTransform(
        pinchScale: Float, rollRadians: Float, orbitDelta: SIMD2<Float>
    ) -> Transform {
        // A non-positive pinch scale is impossible from `pinchScale` (it clamps to 0.2...5), but
        // guarded anyway: the engine refuses a non-positive scale outright, and a gesture must
        // never be the thing that asks for one.
        let scale = pinchScale > 0 ? pinchScale : 1
        return Transform(
            translate: orbitDelta * orbitToUVGain,
            radians: rollRadians,
            scale: scale
        )
    }

    static func transform(
        mode: Mode, from start: SIMD2<Float>, to current: SIMD2<Float>, about centre: SIMD2<Float>
    ) -> Transform {
        switch mode {
        case .move:
            return Transform(translate: current - start)

        case .rotate:
            // The angle swept about the island's centre, so dragging around it turns the island
            // by the same amount the finger travelled — a direct manipulation rather than a gain
            // factor nobody can predict.
            let from = start - centre
            let to = current - centre
            guard simd_length(from) >= minimumLeverArm, simd_length(to) >= minimumLeverArm else {
                return Transform()
            }
            let angle = atan2(to.y, to.x) - atan2(from.y, from.x)
            return Transform(radians: angle)

        case .scale:
            // The RATIO of distances from the centre, so dragging outward grows the island and
            // the gesture is scale-invariant: the same finger travel means the same
            // multiplication on a small island and a large one.
            let fromLength = simd_length(start - centre)
            let toLength = simd_length(current - centre)
            guard fromLength >= minimumLeverArm else { return Transform() }
            let ratio = toLength / fromLength
            // Clamped so one stray sample cannot collapse an island to nothing or explode it off
            // the atlas. A non-positive scale is refused outright by the engine, and this keeps
            // the gesture from ever asking for one.
            return Transform(scale: min(max(ratio, 0.05), 20))
        }
    }
}

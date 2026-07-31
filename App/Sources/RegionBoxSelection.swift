import CyberKit
import Foundation
import simd

// Box selection for the retopology region (openspec add-box-region-selection).
//
// The brush is for irregular areas and for adjusting an edge; a box is for "this
// whole flank", which takes a dozen brush strokes and one drag. Both feed the SAME
// painted region, so the tool the artist reaches for does not change what happens
// next — and erase mode applies to the box too, making it a deselect box.

/// A drag rectangle in normalized viewport coordinates (0...1, origin top-left).
struct SelectionBox: Equatable {
    var origin: SIMD2<Float>
    var corner: SIMD2<Float>

    var minimum: SIMD2<Float> { simd_min(origin, corner) }
    var maximum: SIMD2<Float> { simd_max(origin, corner) }
    var size: SIMD2<Float> { maximum - minimum }

    /// Whether the box is big enough to mean a selection rather than a stray tap.
    /// A tap that resolves to a one-pixel box would select whatever happens to be
    /// under it, which is the brush's job and not this tool's.
    var isMeaningful: Bool { size.x > 0.01 && size.y > 0.01 }

    func contains(_ point: SIMD2<Float>) -> Bool {
        let low = minimum
        let high = maximum
        return point.x >= low.x && point.x <= high.x && point.y >= low.y && point.y <= high.y
    }
}

/// Pure selection geometry: which faces a box covers. No engine, no camera — the
/// projection and the face data are injected, so every rule is unit-testable.
enum RegionBoxSelection {
    /// One candidate face: where it projects to, and which way it faces.
    struct Candidate: Equatable {
        let face: UInt32
        /// Centroid in normalized viewport coordinates.
        let screen: SIMD2<Float>
        /// True when the centroid is in front of the camera. A point behind the
        /// camera projects to a mirrored position inside the box, which would
        /// select the far side of the model from a box drawn on the near side.
        let isInFront: Bool
        /// Dot product of the face normal with the view direction. Negative means
        /// the face turns toward the camera.
        let facingDot: Float
    }

    /// Faces inside `box`, by default only those facing the camera.
    ///
    /// Back faces are excluded because a box drawn over the bunny's flank should take
    /// the flank, not the flank plus the far wall behind it. Occlusion by OTHER
    /// geometry is settled by the caller with a raycast; a normal test cannot see a
    /// wall in between.
    ///
    /// `seesThrough` takes BOTH sides — for a thin feature like an ear, front and
    /// back are one thing to retopologize and boxing them separately means finding a
    /// camera angle for each. Behind-camera candidates are still excluded either way:
    /// a point behind the lens projects to a mirrored position that can land inside
    /// the box, which is not a selection, it is an artefact.
    static func faces(
        in box: SelectionBox, from candidates: [Candidate], seesThrough: Bool = false
    ) -> [UInt32] {
        guard box.isMeaningful else { return [] }
        return candidates.filter { candidate in
            guard candidate.isInFront, box.contains(candidate.screen) else { return false }
            return seesThrough || candidate.facingDot < 0
        }
        // Sorted so the same drag always produces the same carve list, which the
        // solve's determinism depends on.
        .map(\.face)
        .sorted()
    }

    /// Projects a world point to normalized viewport coordinates, reporting whether
    /// it is in front of the camera.
    ///
    /// The inverse of the ray cast the rest of the app uses: same matrix, so a face
    /// the box claims is a face the artist saw inside it.
    static func project(
        _ world: SIMD3<Float>, viewProjection m: [Float]
    ) -> (screen: SIMD2<Float>, isInFront: Bool) {
        guard m.count >= 16 else { return (.zero, false) }
        let x = m[0] * world.x + m[4] * world.y + m[8] * world.z + m[12]
        let y = m[1] * world.x + m[5] * world.y + m[9] * world.z + m[13]
        let w = m[3] * world.x + m[7] * world.y + m[11] * world.z + m[15]
        guard abs(w) > 1e-9 else { return (.zero, false) }
        let ndc = SIMD2(x / w, y / w)
        return (SIMD2(ndc.x * 0.5 + 0.5, 1 - (ndc.y * 0.5 + 0.5)), w > 0)
    }
}

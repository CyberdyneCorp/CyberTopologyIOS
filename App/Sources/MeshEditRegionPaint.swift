import CyberKit
import CyberKitTesting
import Foundation
import simd

// Painting a region of the TARGET to bound auto-retopology (openspec
// add-painted-region-retopo).
//
// Distinct from Freeze Flip, which paints EDITMESH faces to protect them, and
// from Weave Fill's paint, which bounds how far a fill grows from a cage
// boundary. This one names the Target faces the solver may work over.

/// The painted region: Target face ids, in first-touched order.
///
/// Ordered because the ids reach the solver as a carve list and a deterministic
/// order makes the same paint produce the same solve. A `Set` alone would not.
struct PaintedRegion: Equatable {
    private(set) var faces: [UInt32] = []
    private var seen: Set<UInt32> = []

    var isEmpty: Bool { faces.isEmpty }
    var count: Int { faces.count }

    /// Adds faces not already painted, keeping first-touched order.
    mutating func add(_ incoming: [UInt32]) {
        for face in incoming where seen.insert(face).inserted { faces.append(face) }
    }

    mutating func clear() {
        faces.removeAll()
        seen.removeAll()
    }
}

extension MeshEditController {
    /// How wide the paint brush reaches, as a fraction of the scene radius.
    ///
    /// The stroke is sampled along its path and the footprint is raycast as a
    /// RING of screen offsets around each sample, so painting covers a band
    /// rather than a one-face-wide scratch. Screen-space, because the brush is
    /// something the artist aims with their finger, not a world measurement.
    static let regionPaintRadiusFraction: Float = 0.03
    /// Offsets sampled around each stroke point, in units of the brush radius.
    /// Eight around plus the centre: enough to cover the band without turning one
    /// stroke into hundreds of raycasts per sample.
    static let regionPaintFootprint: [SIMD2<Float>] = {
        var offsets: [SIMD2<Float>] = [.zero]
        for step in 0..<8 {
            let angle = Float(step) / 8 * 2 * .pi
            offsets.append(SIMD2(cos(angle), sin(angle)))
        }
        return offsets
    }()

    /// Paint Region: unions the Target faces under the stroke into the painted
    /// region. Nothing is journaled — the region is a statement about what to do
    /// next, not a property of the model (spec: "The painted region is
    /// transient").
    func commitRegionPaintStroke(_ stroke: ToolStroke, samples: [StrokeSample]) {
        let context = stroke.context
        guard let snapper = context.snapper, !samples.isEmpty else { return }
        let radius = Self.regionPaintRadiusFraction
        var painted: [UInt32] = []
        for sample in samples {
            let centre = point(of: sample)
            for offset in Self.regionPaintFootprint {
                let probe = centre + offset * radius
                guard let ray = context.ray(probe),
                    let hit = snapper.raycast(origin: ray.origin, direction: ray.direction)
                else { continue }
                painted.append(hit.face)
            }
        }
        guard !painted.isEmpty else { return }
        paintedRegion.add(painted)
        onPaintedRegionChanged?(paintedRegion.faces)
    }

    /// The region the next auto-retopology should solve: the painted faces, or
    /// the whole Target when nothing is painted.
    var solveRegion: SolveRegion {
        paintedRegion.isEmpty ? .wholeMesh : .faces(paintedRegion.faces)
    }

    /// Empties the painted region and tells the viewport to stop drawing it.
    ///
    /// Called when a solve RUNS — not when it is accepted. A stale extent silently
    /// shaping the next solve is worse than repainting, and the artist has already
    /// seen the proposal by then.
    func clearPaintedRegion() {
        guard !paintedRegion.isEmpty else { return }
        paintedRegion.clear()
        onPaintedRegionChanged?([])
    }
}

/// Pure geometry for the painted-region fill (headless unit tests: the face
/// accessors are injected, so no engine handle is needed).
enum RegionPaintGeometry {
    /// Fan-triangulates each painted face into one buffer set for the ghost
    /// pipeline. Faces whose ring is degenerate or unreadable are skipped rather
    /// than emitted malformed — a stale id after a Target reload is ordinary.
    static func fill(
        faces: [UInt32],
        ring: (UInt32) -> [UInt32],
        position: (UInt32) -> SIMD3<Float>?
    ) -> (positions: [Float], normals: [Float], indices: [UInt32]) {
        var positions: [Float] = []
        var normals: [Float] = []
        var indices: [UInt32] = []
        for face in faces {
            let corners = ring(face).compactMap { position($0) }
            guard corners.count >= 3 else { continue }
            // The face's own plane normal, from the first non-degenerate triple.
            var plane: SIMD3<Float>?
            for index in 1..<(corners.count - 1) {
                let cross = simd_cross(
                    corners[index] - corners[0], corners[index + 1] - corners[0]
                )
                let length = simd_length(cross)
                if length.isFinite, length > .ulpOfOne {
                    plane = cross / length
                    break
                }
            }
            guard let plane else { continue }
            let base = UInt32(positions.count / 3)
            for corner in corners {
                positions.append(contentsOf: [corner.x, corner.y, corner.z])
                normals.append(contentsOf: [plane.x, plane.y, plane.z])
            }
            for index in 1..<(corners.count - 1) {
                indices.append(contentsOf: [base, base + UInt32(index), base + UInt32(index + 1)])
            }
        }
        return (positions, normals, indices)
    }
}

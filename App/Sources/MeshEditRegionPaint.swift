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

    /// Unpaints faces (the erase pass). Order of what remains is preserved, so a
    /// paint-erase-paint sequence still solves deterministically.
    mutating func remove(_ outgoing: [UInt32]) {
        let dropped = Set(outgoing)
        guard !dropped.isEmpty, !faces.isEmpty else { return }
        faces.removeAll { dropped.contains($0) }
        seen.subtract(dropped)
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
    /// How many paint strokes can be stepped back through.
    static let paintHistoryLimit = 32
    static let regionPaintFootprint: [SIMD2<Float>] = {
        var offsets: [SIMD2<Float>] = [.zero]
        for step in 0..<8 {
            let angle = Float(step) / 8 * 2 * .pi
            offsets.append(SIMD2(cos(angle), sin(angle)))
        }
        return offsets
    }()

    /// Whether box selection reaches THROUGH the surface, taking faces on the far
    /// side too. Toggled by a pencil double-tap while the box tool is armed.
    var regionSelectionSeesThrough: Bool {
        get { regionSeesThroughStorage }
        set {
            guard regionSeesThroughStorage != newValue else { return }
            regionSeesThroughStorage = newValue
            onRegionSelectionModeChanged?(newValue)
        }
    }

    /// Whether the paint brush ERASES instead of painting. Toggled by a Pencil
    /// double-tap while the tool is armed — the same gesture other apps use to swap
    /// to an eraser, so it needs no on-screen control.
    var paintErases: Bool {
        get { paintErasesStorage }
        set {
            guard paintErasesStorage != newValue else { return }
            paintErasesStorage = newValue
            onPaintModeChanged?(newValue)
        }
    }

    /// Paint Region, LIVE: paints the Target faces under one sample as the pencil
    /// moves, rather than waiting for the stroke to end.
    ///
    /// Painting at stroke end meant the extent appeared only after lifting the pen,
    /// so a long stroke was drawn blind — reported from device. The work per sample
    /// is a handful of raycasts against the snapper's BVH, which the hover cursor
    /// already does every frame.
    func paintRegionSample(_ sample: StrokeSample, in context: Context) {
        guard let snapper = context.snapper else { return }
        let radius = Self.regionPaintRadiusFraction
        let centre = point(of: sample)
        var touched: [UInt32] = []
        for offset in Self.regionPaintFootprint {
            let probe = centre + offset * radius
            guard let ray = context.ray(probe),
                let hit = snapper.raycast(origin: ray.origin, direction: ray.direction)
            else { continue }
            touched.append(hit.face)
        }
        guard !touched.isEmpty else { return }
        let before = paintedRegion
        if paintErases {
            paintedRegion.remove(touched)
        } else {
            paintedRegion.add(touched)
        }
        // Only redraw when the region actually changed: a stroke lingering over
        // already-painted faces would otherwise re-upload the fill every sample.
        guard paintedRegion != before else { return }
        onPaintedRegionChanged?(paintedRegion.faces)
    }

    /// A paint stroke is starting: remember the region so the whole stroke is ONE
    /// undo step, and drop any redo history (a new stroke forks it).
    func beginPaintStrokeHistory() {
        paintUndoStack.append(paintedRegion)
        // Bounded: the mask is transient anyway, and an unbounded stack on a
        // long session is memory nobody asked for.
        if paintUndoStack.count > Self.paintHistoryLimit { paintUndoStack.removeFirst() }
        paintRedoStack.removeAll()
    }

    var canUndoPaint: Bool { !paintUndoStack.isEmpty }
    var canRedoPaint: Bool { !paintRedoStack.isEmpty }

    /// Undoes one paint stroke. Returns false when there is nothing painted to
    /// undo, so the caller can fall through to the DOCUMENT's undo.
    @discardableResult
    func undoPaint() -> Bool {
        guard let previous = paintUndoStack.popLast() else { return false }
        paintRedoStack.append(paintedRegion)
        paintedRegion = previous
        onPaintedRegionChanged?(paintedRegion.faces)
        return true
    }

    @discardableResult
    func redoPaint() -> Bool {
        guard let next = paintRedoStack.popLast() else { return false }
        paintUndoStack.append(paintedRegion)
        paintedRegion = next
        onPaintedRegionChanged?(paintedRegion.faces)
        return true
    }

    /// Paint history is dropped when the region is cleared or solved: the strokes
    /// described a mask that no longer exists, and stepping back into it after a
    /// solve would resurrect an extent the artist already consumed.
    func clearPaintHistory() {
        paintUndoStack.removeAll()
        paintRedoStack.removeAll()
    }

    /// Box selection: adds every visible Target face inside the drag box to the
    /// region — or removes them when the brush is erasing, which makes the same
    /// gesture a DESELECT box.
    ///
    /// Occluded faces are excluded: a raycast confirms each candidate is the first
    /// thing the camera sees at its centroid, so a box over the flank does not also
    /// take the far wall behind it. That costs one raycast per candidate, which is a
    /// one-shot price at stroke end rather than per sample.
    func commitRegionBoxSelection(
        _ stroke: ToolStroke, first: StrokeSample, last: StrokeSample
    ) {
        let context = stroke.context
        onRegionBoxChanged?(nil)
        let box = SelectionBox(origin: point(of: first), corner: point(of: last))
        guard box.isMeaningful,
            let snapper = context.snapper,
            let target = regionTargetProvider?(),
            let project = context.project,
            let forward = context.camera?.basis.forward
        else { return }

        // Candidates: centroid inside the box, in front of the camera, facing it.
        // `context.project` is the inverse of the ray the rest of the app casts, so a
        // face the box claims is a face the artist saw inside it.
        var candidates: [RegionBoxSelection.Candidate] = []
        for face in target.liveFaceIDs() {
            guard let centroid = target.faceCentroid(face),
                let screen = project(centroid), box.contains(screen)
            else { continue }
            let ring = target.faceVertices(face).compactMap { target.vertexPosition($0) }
            guard ring.count >= 3 else { continue }
            let cross = simd_cross(ring[1] - ring[0], ring[2] - ring[0])
            guard simd_length(cross) > .ulpOfOne else { continue }
            candidates.append(
                RegionBoxSelection.Candidate(
                    face: face, screen: screen, isInFront: true,
                    facingDot: simd_dot(simd_normalize(cross), forward)
                )
            )
        }
        let seesThrough = regionSelectionSeesThrough
        let facing = RegionBoxSelection.faces(
            in: box, from: candidates, seesThrough: seesThrough
        )
        guard !facing.isEmpty else { return }

        // VISIBLE only, unless the box sees through: the first thing the camera sees
        // at the centroid must be this face. Without it a box over the flank also
        // takes the far wall behind it. One raycast per candidate, paid once at
        // stroke end — and skipped entirely in see-through mode, where being hidden
        // is precisely the point.
        let visible: [UInt32]
        if seesThrough {
            visible = facing
        } else {
            var firstHit: [UInt32] = []
            for face in facing {
                guard let centroid = target.faceCentroid(face),
                    let screen = project(centroid),
                    let ray = context.ray(screen),
                    let hit = snapper.raycast(origin: ray.origin, direction: ray.direction)
                else { continue }
                if hit.face == face { firstHit.append(face) }
            }
            visible = firstHit
        }
        guard !visible.isEmpty else { return }

        beginPaintStrokeHistory()
        if paintErases {
            paintedRegion.remove(visible)
        } else {
            paintedRegion.add(visible)
        }
        onPaintedRegionChanged?(paintedRegion.faces)
    }

    /// Publishes the live drag box so the viewport can draw it.
    func regionBoxDragged(_ stroke: ToolStroke, first: StrokeSample, current: StrokeSample) {
        let box = SelectionBox(origin: point(of: first), corner: point(of: current))
        onRegionBoxChanged?(box.isMeaningful ? box : nil)
    }

    /// The region the next auto-retopology should solve: the painted faces, or
    /// the whole Target when nothing is painted.
    var solveRegion: SolveRegion {
        paintedRegion.isEmpty ? .wholeMesh : .faces(paintedRegion.faces)
    }

    /// The brush footprint in WORLD units at `point`, for the hover ring: the
    /// screen-space radius projected onto the surface distance the artist is
    /// looking at.
    static func brushWorldRadius(sceneRadius: Float) -> Float {
        sceneRadius * regionPaintRadiusFraction
    }

    /// Empties the painted region and tells the viewport to stop drawing it.
    ///
    /// Called when a solve RUNS — not when it is accepted. A stale extent silently
    /// shaping the next solve is worse than repainting, and the artist has already
    /// seen the proposal by then.
    func clearPaintedRegion() {
        clearPaintHistory()
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
        faces: [UInt32], corners cornersOf: (UInt32) -> [SIMD3<Float>]
    ) -> (positions: [Float], normals: [Float], indices: [UInt32]) {
        var positions: [Float] = []
        var normals: [Float] = []
        var indices: [UInt32] = []
        for face in faces {
            let corners = cornersOf(face)
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

/// What a pencil double-tap does, which depends on the armed tool.
///
/// The gesture is the one other apps use to reach an eraser, and each region tool has
/// its own most-wanted switch: the brush needs to stop adding and start removing, a
/// box needs to reach the far side of a thin feature. Binding it per tool gives each
/// the meaning that matters there instead of one compromise.
enum PencilTapAction: Equatable {
    case toggleErase
    case toggleSeeThrough
    /// No region tool armed: the tap is left for whatever else wants it rather than
    /// being silently swallowed.
    case none

    static func forTool(_ tool: RetopoTool?) -> PencilTapAction {
        switch tool {
        case .paintRegion: return .toggleErase
        case .selectRegionBox: return .toggleSeeThrough
        default: return .none
        }
    }
}

/// Per-face corner positions for the painted-extent fill, cached.
///
/// WHY THIS EXISTS. The extent is rebuilt on every paint sample, and it used to
/// fetch the Target by calling `bundle.mesh(for:)` — which DESERIALIZES the whole
/// mesh from its payload bytes. On a 69 451-face Target at pencil sample rates that
/// is ~120 full mesh rebuilds a second, which is the "faces appear seconds later"
/// reported from device. On top of it, every painted face cost a `faceVertices` plus
/// three or four `vertexPosition` calls into the engine, on every sample, for faces
/// whose geometry had not moved since the last one.
///
/// The Target is fixed while painting — it is only ever the surface — so both are
/// cacheable. Keyed by payload identity so a reimported or edited Target invalidates
/// itself rather than drawing the old shape.
struct RegionPaintFaceCache {
    private(set) var key: String?
    private var corners: [UInt32: [SIMD3<Float>]] = [:]
    /// How many times the cache had to ask the engine — asserted in tests, since a
    /// cache that silently stops hitting is the bug it exists to prevent.
    private(set) var fetches = 0

    /// Drops everything when the Target changes identity.
    mutating func prepare(key: String) {
        guard key != self.key else { return }
        self.key = key
        corners.removeAll()
        fetches = 0
    }

    /// Corners of `face`, fetching once and remembering.
    mutating func corners(
        of face: UInt32, fetch: (UInt32) -> [SIMD3<Float>]
    ) -> [SIMD3<Float>] {
        if let cached = corners[face] { return cached }
        fetches += 1
        let fetched = fetch(face)
        corners[face] = fetched
        return fetched
    }
}

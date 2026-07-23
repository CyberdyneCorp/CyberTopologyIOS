import CyberRemesherC
import Foundation
import simd

// Symmetry (task 4.4; spec: retopology-tools / "Multi-axis and radial
// symmetry").
//
// Two halves live here:
//
//   - `SymmetrySettings` + `SymmetryReplica`: the PURE, headless-testable
//     description of what symmetry is on — which mirror axes, where the
//     origin sits, how many radial sectors — and the derived list of
//     rigid transforms an authored operation must be replayed under.
//     Live symmetric authoring is exactly "run the engine op once per
//     replica inside ONE journaled transaction", so undo removes every
//     side together.
//   - Engine facades on `Mesh` (engine patch 0021): center-line weld,
//     apply-symmetry (bakes the mirror into real geometry) and
//     re-symmetrize (mirrors one half onto the other preserving topology).
//     All the geometry runs engine-side per design D1.

/// Persistent symmetry state of a document (spec: "mirror symmetry on any
/// combination of X/Y/Z axes with configurable origin, and radial symmetry
/// with configurable count").
///
/// Value type, `Codable` for the manifest and `Equatable` so a journaled
/// change can be compared exactly. Encoding is deterministic: `mirrorAxes`
/// is always stored sorted and deduplicated, so two equal settings encode
/// to identical bytes.
public struct SymmetrySettings: Codable, Equatable, Sendable {
    /// A world axis; the mirror plane for an axis is the plane through
    /// `origin` whose NORMAL is that axis (mirroring on X reflects the x
    /// coordinate about the origin's x).
    public enum Axis: String, Codable, Equatable, Sendable, CaseIterable {
        case x, y, z

        /// Unit normal of this axis' mirror plane.
        public var normal: SIMD3<Float> {
            switch self {
            case .x: return SIMD3(1, 0, 0)
            case .y: return SIMD3(0, 1, 0)
            case .z: return SIMD3(0, 0, 1)
            }
        }
    }

    /// Radial sector counts the UI offers and the settings accept.
    public static let radialCountRange = 1...32
    /// Default center-line weld tolerance, as a fraction of the scene
    /// radius the caller scales it by.
    public static let defaultWeldFraction: Float = 0.005

    /// Enabled mirror axes — stored sorted and deduplicated. Empty means
    /// no mirroring (radial symmetry can still be on).
    public private(set) var mirrorAxes: [Axis]
    /// World-space origin every symmetry plane and the radial axis pass
    /// through.
    public var origin: SIMD3<Float>
    /// Radial sector count; 1 means radial symmetry is off. Clamped into
    /// `radialCountRange`.
    public private(set) var radialCount: Int
    /// Axis the radial sectors rotate about.
    public var radialAxis: Axis
    /// Vertices this close to a symmetry plane are treated as ON it: they
    /// weld onto the plane and are shared by both halves.
    public var weldTolerance: Float
    /// Which half is authored: the half the plane normal points into
    /// (true) or away from (false).
    public var workingSidePositive: Bool
    /// Master switch. Off keeps the configured axes/origin so toggling
    /// back restores the user's setup.
    public var isEnabled: Bool

    public init(
        mirrorAxes: [Axis] = [], origin: SIMD3<Float> = .zero, radialCount: Int = 1,
        radialAxis: Axis = .y, weldTolerance: Float = 1e-4,
        workingSidePositive: Bool = true, isEnabled: Bool = false
    ) {
        self.mirrorAxes = Self.normalized(mirrorAxes)
        self.origin = origin
        self.radialCount = Self.clampedRadialCount(radialCount)
        self.radialAxis = radialAxis
        self.weldTolerance = max(0, weldTolerance)
        self.workingSidePositive = workingSidePositive
        self.isEnabled = isEnabled
    }

    /// Sorted, deduplicated axis list (deterministic encoding).
    private static func normalized(_ axes: [Axis]) -> [Axis] {
        Axis.allCases.filter(axes.contains)
    }

    private static func clampedRadialCount(_ count: Int) -> Int {
        min(max(count, radialCountRange.lowerBound), radialCountRange.upperBound)
    }

    /// Decoding re-runs the normalization/clamping, so a hand-edited or
    /// future-build manifest can never inject an unsorted axis list or an
    /// out-of-range sector count into the replication math.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            mirrorAxes: try container.decodeIfPresent([Axis].self, forKey: .mirrorAxes) ?? [],
            origin: try container.decodeIfPresent(SIMD3<Float>.self, forKey: .origin) ?? .zero,
            radialCount: try container.decodeIfPresent(Int.self, forKey: .radialCount) ?? 1,
            radialAxis: try container.decodeIfPresent(Axis.self, forKey: .radialAxis) ?? .y,
            weldTolerance: try container.decodeIfPresent(Float.self, forKey: .weldTolerance)
                ?? 1e-4,
            workingSidePositive: try container.decodeIfPresent(
                Bool.self, forKey: .workingSidePositive) ?? true,
            isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        )
    }

    // MARK: - Mutation (keeps the stored invariants)

    /// This state with `axis` mirroring turned on or off.
    public func settingMirror(_ axis: Axis, enabled: Bool) -> SymmetrySettings {
        var copy = self
        copy.mirrorAxes = Self.normalized(
            enabled ? mirrorAxes + [axis] : mirrorAxes.filter { $0 != axis }
        )
        return copy
    }

    /// This state with a new radial sector count (clamped).
    public func settingRadialCount(_ count: Int) -> SymmetrySettings {
        var copy = self
        copy.radialCount = Self.clampedRadialCount(count)
        return copy
    }

    // MARK: - Derived state

    /// True when the settings would actually replicate anything: enabled,
    /// and with at least one mirror axis or more than one radial sector.
    public var isActive: Bool {
        isEnabled && (!mirrorAxes.isEmpty || radialCount > 1)
    }

    /// Mirror plane of `axis`, as the engine's plane description.
    public func plane(for axis: Axis) -> (origin: SIMD3<Float>, normal: SIMD3<Float>) {
        (origin, axis.normal)
    }

    /// The rigid transforms an authored operation must ALSO be replayed
    /// under, excluding the identity (the authored operation itself).
    ///
    /// Order is deterministic: mirror subsets in axis order (as a bit mask
    /// over `mirrorAxes`), and within each subset the radial sectors in
    /// increasing angle. The count is `2^mirrorAxes.count * radialCount - 1`.
    public var replicas: [SymmetryReplica] {
        guard isActive else { return [] }
        var result: [SymmetryReplica] = []
        for mask in 0..<(1 << mirrorAxes.count) {
            let axes = mirrorAxes.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
            for sector in 0..<radialCount where !(mask == 0 && sector == 0) {
                result.append(replica(mirroring: axes, sector: sector))
            }
        }
        return result
    }

    /// One replica: rotate by the sector angle, then mirror on `axes`.
    private func replica(mirroring axes: [Axis], sector: Int) -> SymmetryReplica {
        var transform = Self.rotation(about: radialAxis, sector: sector, of: radialCount)
        for axis in axes {
            transform = Self.mirror(about: axis).concatenating(transform)
        }
        return SymmetryReplica(
            transform: Self.translated(transform, aboutOrigin: origin),
            reversesWinding: axes.count % 2 == 1
        )
    }

    // MARK: - Transform builders (origin-relative linear parts)

    /// Reflection about the plane with `axis` as its normal, through the
    /// world origin.
    private static func mirror(about axis: Axis) -> MeshTransform {
        let n = axis.normal
        return MeshTransform(
            columns: (
                SIMD3(1, 0, 0) - 2 * n.x * n,
                SIMD3(0, 1, 0) - 2 * n.y * n,
                SIMD3(0, 0, 1) - 2 * n.z * n
            ),
            translation: .zero
        )
    }

    /// Rotation about `axis` through the world origin by `sector` steps of
    /// a full turn divided into `count`.
    private static func rotation(about axis: Axis, sector: Int, of count: Int) -> MeshTransform {
        guard count > 1, sector % count != 0 else { return .identity }
        let angle = 2 * Float.pi * Float(sector) / Float(count)
        let q = simd_quatf(angle: angle, axis: axis.normal)
        let m = simd_float3x3(q)
        return MeshTransform(
            columns: (m.columns.0, m.columns.1, m.columns.2), translation: .zero
        )
    }

    /// Re-anchors a world-origin linear transform so it acts about
    /// `origin` instead: `p -> L(p - o) + o`.
    private static func translated(
        _ transform: MeshTransform, aboutOrigin origin: SIMD3<Float>
    ) -> MeshTransform {
        MeshTransform(
            columns: transform.columns,
            translation: origin - transform.applyDirection(origin)
        )
    }
}

extension MeshTransform {
    /// `self ∘ other` (apply `other` first).
    func concatenating(_ other: MeshTransform) -> MeshTransform {
        MeshTransform(
            columns: (
                applyDirection(other.columns.0),
                applyDirection(other.columns.1),
                applyDirection(other.columns.2)
            ),
            translation: apply(other.translation)
        )
    }
}

/// One symmetric copy of an authored operation.
///
/// `transform` maps authored world points onto the copy's world points.
/// `reversesWinding` records that the transform has negative determinant
/// (an odd number of reflections): face rings must be traversed backwards
/// so the copy keeps the same outward orientation as the original.
public struct SymmetryReplica: Equatable, Sendable {
    public var transform: MeshTransform
    public var reversesWinding: Bool

    public init(transform: MeshTransform, reversesWinding: Bool) {
        self.transform = transform
        self.reversesWinding = reversesWinding
    }

    /// This replica's copy of a single world point.
    public func apply(_ point: SIMD3<Float>) -> SIMD3<Float> { transform.apply(point) }

    /// This replica's copy of a face ring — transformed AND, for a
    /// reflecting replica, reversed so the winding survives.
    public func apply(ring: [SIMD3<Float>]) -> [SIMD3<Float>] {
        let moved = ring.map(transform.apply)
        return reversesWinding ? moved.reversed() : moved
    }

    /// This replica's copy of an open point sequence (a stroke path): the
    /// same transform WITHOUT the ring reversal — a path has no winding.
    public func apply(path: [SIMD3<Float>]) -> [SIMD3<Float>] {
        path.map(transform.apply)
    }

    /// This replica's copy of `points`, reordered as `layout` requires so
    /// the created faces keep their outward orientation under a
    /// reflecting replica.
    public func apply(
        points: [SIMD3<Float>], layout: SymmetryPointLayout
    ) -> [SIMD3<Float>] {
        let moved = points.map(transform.apply)
        guard reversesWinding else { return moved }
        switch layout {
        case .path:
            return moved
        case .ring:
            return moved.reversed()
        case .grid(let cols):
            return Self.reversingRows(moved, cols: cols)
        }
    }

    /// Reverses each row of a row-major `(n) x (cols + 1)` lattice. Every
    /// cell's ring is thereby traversed the other way round, which is
    /// exactly the winding correction a single reflection needs — and it
    /// keeps the lattice a lattice, which reversing the whole array would
    /// not.
    private static func reversingRows(
        _ lattice: [SIMD3<Float>], cols: Int
    ) -> [SIMD3<Float>] {
        let stride = cols + 1
        guard stride > 1, lattice.count % stride == 0 else { return lattice }
        return Swift.stride(from: 0, to: lattice.count, by: stride)
            .flatMap { lattice[$0..<($0 + stride)].reversed() }
    }
}

/// How a list of authored world points is laid out, which decides how a
/// REFLECTING symmetry replica has to reorder them to keep the created
/// geometry's winding.
public enum SymmetryPointLayout: Equatable, Sendable {
    /// A single face ring — reverse it.
    case ring
    /// A row-major `(rows + 1) x (cols + 1)` lattice — reverse each row.
    case grid(cols: Int)
    /// An open path (stroke samples) — order carries no winding.
    case path
}

/// What a re-symmetrize pass did (engine report).
public struct ResymmetrizeReport: Equatable, Sendable {
    /// Vertices welded onto the symmetry plane before matching. This is a
    /// POPULATION count (vertices within the weld tolerance, including
    /// ones already exactly on the plane), not a change signal —
    /// `maxCorrection` is the change signal.
    public var snappedToPlane: Int
    /// Off-side vertices moved exactly onto their mirror counterpart.
    public var matched: Int
    /// Off-side vertices with no counterpart within the match tolerance —
    /// geometry that exists on one side only, deliberately left alone
    /// (the spec's "preserving topology correspondence WHERE IT EXISTS").
    public var unmatched: Int
    /// Largest displacement applied; 0 when the mesh was already symmetric.
    public var maxCorrection: Float

    public init(
        snappedToPlane: Int, matched: Int, unmatched: Int, maxCorrection: Float
    ) {
        self.snappedToPlane = snappedToPlane
        self.matched = matched
        self.unmatched = unmatched
        self.maxCorrection = maxCorrection
    }

    /// True when NOTHING MOVED — the mesh was already symmetric about the
    /// chosen plane. `maxCorrection` covers both halves of the pass (the
    /// center-line weld and the mirror correction), so it alone decides.
    public var isNoOp: Bool { maxCorrection == 0 }
}

extension Mesh {
    /// Builds the capi plane description for one axis of `settings`.
    private static func engineSymmetry(
        _ settings: SymmetrySettings, axis: SymmetrySettings.Axis
    ) -> CyberSymmetry {
        let plane = settings.plane(for: axis)
        return CyberSymmetry(
            origin: (plane.origin.x, plane.origin.y, plane.origin.z),
            normal: (plane.normal.x, plane.normal.y, plane.normal.z),
            weld_tolerance: settings.weldTolerance,
            working_side_positive: settings.workingSidePositive ? 1 : 0
        )
    }

    /// Snaps every vertex within the weld tolerance of the `axis` plane
    /// exactly onto it (spec: "Center-line vertices SHALL snap to the
    /// symmetry plane"). Returns the number of vertices snapped. Topology
    /// is untouched.
    @discardableResult
    public func snapToSymmetryPlane(
        _ settings: SymmetrySettings, axis: SymmetrySettings.Axis
    ) throws -> Int {
        var symmetry = Self.engineSymmetry(settings, axis: axis)
        var snapped = 0
        try check(cyber_retopo_snap_symmetry_plane(handle, &symmetry, &snapped))
        return snapped
    }

    /// Snaps center-line vertices onto EVERY enabled mirror plane, in axis
    /// order. Returns the total number of snap operations applied (a
    /// vertex on two planes counts once per plane).
    @discardableResult
    public func snapToSymmetryPlanes(_ settings: SymmetrySettings) throws -> Int {
        try settings.mirrorAxes.reduce(0) { total, axis in
            total + (try snapToSymmetryPlane(settings, axis: axis))
        }
    }

    /// Upper bound on how many vertices may be welded at ONE seam point.
    /// A 2-mirror corner can legitimately stack four coincident vertices;
    /// the bound only stops a pathological mesh from looping forever.
    private static let maximumSeamWeldsPerPoint = 8

    /// Welds the DUPLICATE vertices a mirrored authoring stroke leaves on
    /// the symmetry plane.
    ///
    /// `snapToSymmetryPlanes` only calls `setPosition` — topology is
    /// untouched — so an authored face and its mirrored twin each keep
    /// their OWN vertex at the same on-plane location. The center line is
    /// then a crack: the two halves share no vertex, boundary walks find a
    /// rim that should not exist, Relax/Move treat the seam as two open
    /// boundaries, and export produces a split mesh. This pass merges each
    /// such stack down to one vertex, which is what makes the seam
    /// manifold.
    ///
    /// `points` are the world points the stroke authored (every replica's
    /// ring). Only those within `searchRadius` of an enabled plane are
    /// considered — the pass never touches geometry away from the seam.
    ///
    /// **The authored points are a LOCATOR, not the seam position** — that
    /// is what `searchRadius` exists for. Between authoring and this call
    /// the created vertices are projected onto the Target
    /// (`createFace(snapping:)`) and then onto the plane
    /// (`snapToSymmetryPlanes`), so a locator is only an approximation of
    /// where its vertex ended up. The `keep` lookup therefore runs at the
    /// generous `searchRadius` and the tight `weldTolerance` is applied
    /// where it is meaningful: between the RESOLVED vertex's real position
    /// and its coincident duplicates, and as the on-plane membership test
    /// that keeps the pass from dragging off-seam geometry onto the center
    /// line.
    ///
    /// **This is the COINCIDENCE pass, for callers that only have a flat
    /// point list** (apply-symmetry bakes, tests). It closes the seam only
    /// when the twins really are coincident — on an ASYMMETRIC Target the snap
    /// inside `createFace` can leave them on the plane but further apart than
    /// `weldTolerance`, and widening the radius would swallow unrelated
    /// on-plane cage vertices. The authoring path (`applyCreate`) no longer
    /// relies on this: it captures each copy's created vertices and calls the
    /// PROVENANCE overload `weldSeamVertices(_:rings:created:searchRadius:)`,
    /// which pairs twins by the ring they came from and closes the seam
    /// regardless of the snap drift. See
    /// `SymmetryToolsTests/curvedTargetSeamResidual`.
    ///
    /// - Parameter searchRadius: how far from an authored point to look for
    ///   the vertex it became. Callers that snap to a Target should pass
    ///   their pick radius. Defaults to the weld tolerance (exact-location
    ///   lookup), which is right only when nothing moved the vertices.
    ///
    /// Returns the number of merges performed.
    @discardableResult
    public func weldSeamVertices(
        _ settings: SymmetrySettings, near points: [SIMD3<Float>],
        searchRadius: Float? = nil
    ) throws -> Int {
        let tolerance = settings.weldTolerance
        guard tolerance > 0, !points.isEmpty, !settings.mirrorAxes.isEmpty else { return 0 }
        let search = max(searchRadius ?? tolerance, tolerance)
        var welded = 0
        for axis in settings.mirrorAxes {
            let plane = settings.plane(for: axis)
            // Seam locators: authored points near the plane, projected onto
            // it, de-duplicated so a shared corner is processed once. The
            // near-plane test uses `search` for the same reason the lookup
            // does — the authored point is only an approximation of where
            // its vertex ended up.
            var seeds: [SIMD3<Float>] = []
            for point in points {
                let signedDistance = simd_dot(point - plane.origin, plane.normal)
                guard abs(signedDistance) <= search else { continue }
                let projected = point - plane.normal * signedDistance
                guard !seeds.contains(where: { simd_distance($0, projected) <= tolerance })
                else { continue }
                seeds.append(projected)
            }
            var resolved: Set<UInt32> = []
            for seed in seeds {
                guard let keep = nearestVertex(to: seed, maxDistance: search),
                    let anchor = vertexPosition(keep.vertex)
                else { continue }
                // The vertex has to be ON the plane to be a seam vertex: a
                // locator whose vertex the Target pulled off the plane was
                // not snapped either, and welding it would drag unrelated
                // geometry onto the center line.
                guard abs(simd_dot(anchor - plane.origin, plane.normal)) <= tolerance,
                    resolved.insert(keep.vertex).inserted
                else { continue }
                for _ in 0..<Self.maximumSeamWeldsPerPoint {
                    guard
                        let duplicate = nearestVertex(
                            to: anchor, maxDistance: tolerance, excluding: keep.vertex
                        )
                    else { break }
                    // `keep`'s position wins: it is already exactly on the
                    // plane, so no midpoint averaging can drift it off.
                    try mergeVertices(keep: keep.vertex, remove: duplicate.vertex)
                    welded += 1
                }
            }
        }
        return welded
    }

    /// PROVENANCE-aware seam weld (task 4.4b) — the fix for the residual the
    /// coincidence pass above leaves on ASYMMETRIC Targets. Instead of pairing
    /// twins by where the Target snap left them (which fails when the mirrored
    /// copy of a near-plane corner snaps differently from the authored one, or
    /// when the two are symmetric about the plane and a single search point
    /// cannot tell them apart), this pairs them by the ring they came from.
    ///
    /// `rings[c]` is copy c's authored corner locators (copy 0 = the authored
    /// ring, the rest its symmetric replicas) and `created[c]` is the set of
    /// vertices copy c CREATED — captured by the caller as a live-id diff
    /// around each build, before any snap moved them. A corner ON a mirror
    /// plane is a reflection FIXED POINT, so every copy that reaches the seam
    /// shares the exact same PRE-SNAP locator there; grouping by that locator
    /// pairs the twins with no radius guessing. Within one copy the near-plane
    /// vertex is the only created vertex close to that corner (the far corners
    /// are a whole edge away), so it resolves unambiguously even after the
    /// snap drifted it off the locator.
    ///
    /// Returns the number of merges performed.
    @discardableResult
    public func weldSeamVertices(
        _ settings: SymmetrySettings, rings: [[SIMD3<Float>]],
        created: [[UInt32]], searchRadius: Float? = nil
    ) throws -> Int {
        let tolerance = settings.weldTolerance
        guard tolerance > 0, !settings.mirrorAxes.isEmpty,
            rings.count == created.count, !rings.isEmpty
        else { return 0 }
        let search = max(searchRadius ?? tolerance, tolerance)
        var welded = 0
        var removed = Set<UInt32>()
        for axis in settings.mirrorAxes {
            let plane = settings.plane(for: axis)
            // Per-copy seam vertices, keyed by their projected-on-plane
            // location so fixed-point twins group together.
            var keys: [SIMD3<Float>] = []
            var vertices: [UInt32] = []
            for copy in rings.indices {
                for corner in rings[copy] {
                    let signedDistance = simd_dot(corner - plane.origin, plane.normal)
                    // A SEAM corner is one the user drew ON the plane: gated at
                    // the tight weld tolerance, which is exactly the band
                    // `snapToSymmetryPlanes` pulls onto the plane. The generous
                    // `search` is only for RESOLVING the vertex the corner
                    // became — using it as the seam gate would let a far corner
                    // (a whole edge away) in, and its projection onto the plane
                    // would then share a key with the opposite copy's far
                    // corner and wrongly weld them.
                    guard abs(signedDistance) <= tolerance else { continue }
                    guard let vertex = nearestCreatedVertex(
                        in: created[copy], to: corner, within: search, excluding: removed
                    ) else { continue }
                    keys.append(corner - plane.normal * signedDistance)
                    vertices.append(vertex)
                }
            }
            // Group by key coincidence; merge each group to one shared vertex.
            var used = [Bool](repeating: false, count: vertices.count)
            for i in vertices.indices where !used[i] {
                var group = [vertices[i]]
                used[i] = true
                for j in (i + 1)..<vertices.count where !used[j] {
                    guard simd_distance(keys[i], keys[j]) <= tolerance else { continue }
                    used[j] = true
                    if !group.contains(vertices[j]) { group.append(vertices[j]) }
                }
                guard group.count > 1 else { continue }
                // Keep a vertex already exactly on the plane (the snap put the
                // seam vertices there), so no merge drifts the seam off it.
                let keep = group.first { vertex in
                    guard let position = vertexPosition(vertex) else { return false }
                    return abs(simd_dot(position - plane.origin, plane.normal)) <= tolerance
                } ?? group[0]
                for vertex in group where vertex != keep && !removed.contains(vertex) {
                    try mergeVertices(keep: keep, remove: vertex)
                    removed.insert(vertex)
                    welded += 1
                }
            }
        }
        return welded
    }

    /// The vertex in `ids` closest to `point`, within `radius`, skipping the
    /// already-merged. Positions are read live, so a merged (dead) id returns
    /// nil and is ignored.
    private func nearestCreatedVertex(
        in ids: [UInt32], to point: SIMD3<Float>, within radius: Float,
        excluding removed: Set<UInt32>
    ) -> UInt32? {
        var best: UInt32?
        var bestDistance = radius
        for id in ids where !removed.contains(id) {
            guard let position = vertexPosition(id) else { continue }
            let distance = simd_distance(position, point)
            if distance <= bestDistance {
                bestDistance = distance
                best = id
            }
        }
        return best
    }

    /// Apply-symmetry: BAKES the mirror into real geometry for one axis.
    /// Every face wholly on the working side gains a mirrored twin with
    /// reversed winding; on-plane vertices weld to themselves so the seam
    /// stays manifold. Returns the number of faces added.
    @discardableResult
    public func applySymmetry(
        _ settings: SymmetrySettings, axis: SymmetrySettings.Axis,
        snapping snapper: SurfaceSnapper? = nil
    ) throws -> Int {
        var symmetry = Self.engineSymmetry(settings, axis: axis)
        var added = 0
        try check(cyber_retopo_apply_symmetry(handle, &symmetry, snapper?.handle, &added))
        return added
    }

    /// Apply-symmetry across every enabled mirror axis, in axis order (an
    /// X+Y bake mirrors the quadrant into all four). Returns the total
    /// number of faces added.
    ///
    /// Radial symmetry is NOT baked here: welding the sector seams is
    /// tolerance-sensitive and has no engine support (task 4.4a).
    @discardableResult
    public func applySymmetry(
        _ settings: SymmetrySettings, snapping snapper: SurfaceSnapper? = nil
    ) throws -> Int {
        try settings.mirrorAxes.reduce(0) { total, axis in
            total + (try applySymmetry(settings, axis: axis, snapping: snapper))
        }
    }

    /// Re-symmetrize: mirrors the working half onto the other half about
    /// `axis`, IN PLACE. Adds and removes nothing, so topology
    /// correspondence is preserved exactly; off-side vertices with no
    /// counterpart within `matchTolerance` are reported as `unmatched`
    /// and left untouched.
    @discardableResult
    public func resymmetrize(
        _ settings: SymmetrySettings, axis: SymmetrySettings.Axis, matchTolerance: Float
    ) throws -> ResymmetrizeReport {
        var symmetry = Self.engineSymmetry(settings, axis: axis)
        var report = CyberResymmetrizeReport()
        try check(cyber_retopo_resymmetrize(handle, &symmetry, matchTolerance, &report))
        return ResymmetrizeReport(
            snappedToPlane: Int(report.snapped),
            matched: Int(report.matched),
            unmatched: Int(report.unmatched),
            maxCorrection: report.max_correction
        )
    }
}

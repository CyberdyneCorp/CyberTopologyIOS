import Foundation
import simd

/// The Weave solver-session layer (Phase 5).
///
/// A solve turns a region of a mesh plus a set of constraints into a *ghost*
/// mesh — proposed, uncommitted geometry the app renders and the user accepts
/// or discards. This file defines the API surface and its first backend,
/// `EngineRemeshSolver`, which wraps the engine's existing auto-retopology
/// (`cyber_remesh`). The constraint-aware Weave solver lands later behind the
/// same `WeaveSolving` protocol, so nothing above the protocol changes when it
/// arrives. See `openspec/changes/add-weave-solver-pipeline`.

/// The region a solve operates over.
///
/// `.wholeMesh` is the maximal region ("solve all"), handled by
/// `EngineRemeshSolver`. `.faces` is a connected sub-region rewritten IN PLACE
/// against frozen surrounding topology, handled by `RegionWeaveSolver`; route
/// between them with `CompositeWeaveSolver`.
///
/// **`.faces(everyLiveFace)` is NOT equivalent to `.wholeMesh`.** The region
/// path preserves element ids and deliberately skips triangulate / weld /
/// orient / islands / hole-fill / pure-quads, so it is a different operation,
/// not an optimisation of the same one. The engine REFUSES that case rather
/// than aliasing it — treating them as interchangeable would be a lie.
public enum SolveRegion: Equatable, Sendable {
    case wholeMesh
    case faces([UInt32])
}

/// A colour-tagged loop — a flow constraint for the constraint-aware solver.
/// Stored now for forward-compatibility; not honoured by `EngineRemeshSolver`.
public struct TaggedLoop: Equatable, Codable, Sendable {
    public var edges: [UInt32]
    public var colorIndex: Int
    public init(edges: [UInt32], colorIndex: Int) {
        self.edges = edges
        self.colorIndex = colorIndex
    }
}

/// A guide stroke drawn on bare surface — a soft orientation hint for the
/// constraint-aware solver. Stored now; not honoured by `EngineRemeshSolver`.
public struct GuideStroke: Equatable, Codable, Sendable {
    public var points: [SIMD3<Float>]
    public init(points: [SIMD3<Float>]) { self.points = points }
}

/// A target edge-length field — the density constraint. For now a single global
/// value; a per-region brush map is a later addition. Not honoured by
/// `EngineRemeshSolver` beyond what `SolverParameters.remesh` already carries.
public struct DensityField: Equatable, Codable, Sendable {
    /// Global multiplier on the derived edge length. Unchanged from 5.2.
    public var targetEdgeLength: Float
    /// AUTHORED per-vertex multipliers — the density BRUSH
    /// (openspec add-weave-density-radial-symmetry). Indexed by vertex id; > 1 is
    /// coarser, < 1 is finer. Entries past the end read as 1.0, so a caller need not
    /// size this to the mesh. Empty (the default) is exactly the pre-5.2b behaviour.
    ///
    /// MULTIPLIED into the solver's curvature-derived scales and clamped to the same
    /// [0.3, 3.0] band, so painting coarse does not throw away detail preservation the
    /// artist did not ask to lose, and the composition does not depend on order.
    ///
    /// Honoured by a REGION solve. The whole-mesh path remeshes per island and island
    /// extraction renumbers vertices, so these indices would not survive it.
    public var perVertex: [Float]

    public init(targetEdgeLength: Float, perVertex: [Float] = []) {
        self.targetEdgeLength = targetEdgeLength
        self.perVertex = perVertex
    }

    private enum CodingKeys: String, CodingKey { case targetEdgeLength, perVertex }

    /// Explicit decode so documents written before the brush existed still load: the
    /// SYNTHESIZED conformance treats `perVertex` as required and throws `keyNotFound`
    /// on every pre-5.2b document. Caught by test, not by review — the same
    /// decodeIfPresent pattern `MeshAnnotations` and `SymmetrySettings` already use for
    /// exactly this reason.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            targetEdgeLength: try container.decode(Float.self, forKey: .targetEdgeLength),
            perVertex: try container.decodeIfPresent([Float].self, forKey: .perVertex) ?? []
        )
    }
}

/// The full Weave constraint taxonomy. This slice STORES all of it so call
/// sites and the document are forward-compatible, but `EngineRemeshSolver`
/// honours only what the auto-remesher inherently does (region + never touching
/// the source). Field honouring — flow, orientation, pins-as-hard, density —
/// belongs to the constraint-aware backend.
public struct WeaveConstraints: Equatable, Codable, Sendable {
    public var frozenFaces: [UInt32]
    public var taggedLoops: [TaggedLoop]
    public var guideStrokes: [GuideStroke]
    public var pinnedVertices: [UInt32]
    public var density: DensityField?
    public var symmetry: SymmetrySettings?

    /// Per-vertex prescribed TOTAL valence on a region solve's interface, so a
    /// deliberately authored pole is not reported as irregular. Region solves
    /// only; ignored by the whole-mesh backend.
    public var interfaceValence: [UInt32: Int]

    public init(
        frozenFaces: [UInt32] = [],
        taggedLoops: [TaggedLoop] = [],
        guideStrokes: [GuideStroke] = [],
        pinnedVertices: [UInt32] = [],
        density: DensityField? = nil,
        symmetry: SymmetrySettings? = nil,
        interfaceValence: [UInt32: Int] = [:]
    ) {
        self.frozenFaces = frozenFaces
        self.taggedLoops = taggedLoops
        self.guideStrokes = guideStrokes
        self.pinnedVertices = pinnedVertices
        self.density = density
        self.symmetry = symmetry
        self.interfaceValence = interfaceValence
    }
}

/// Solver parameters. `remesh` drives the auto-remesh backend; `seed` fixes any
/// randomness so a solve is reproducible (part of the determinism contract).
public struct SolverParameters: Equatable, Sendable {
    public var remesh: RemeshParameters
    public var seed: UInt64
    public init(remesh: RemeshParameters = RemeshParameters(), seed: UInt64 = 0) {
        self.remesh = remesh
        self.seed = seed
    }

    /// One-tap Auto-Retopo default: a moderate quad budget. The engine's raw
    /// default (`targetQuads` 50 000) is far too fine for interactive use, so
    /// the Weave layer picks a middling density.
    public static var autoRetopoDefault: SolverParameters { medium }

    /// Density presets driving the solve's quad budget (the engine's raw
    /// default is unusably fine for interactive retopology).
    public static var coarse: SolverParameters { withTargetQuads(600) }
    public static var medium: SolverParameters { withTargetQuads(1500) }
    public static var fine: SolverParameters { withTargetQuads(4000) }

    /// Parameters targeting a specific output quad budget (clamped to a sane
    /// floor so a stray value cannot request zero/negative quads). Used by the
    /// Auto-Retopo face-count options (Same / Double / Half / Custom relative to
    /// the Target).
    public static func targetingQuads(_ count: Int) -> SolverParameters {
        withTargetQuads(max(4, count))
    }

    private static func withTargetQuads(_ count: Int) -> SolverParameters {
        var params = SolverParameters()
        params.remesh.targetQuads = count
        return params
    }
}

/// Advisory progress from a running solve.
public struct SolverProgress: Equatable, Sendable {
    public var fraction: Double
    public var stage: String
    public init(fraction: Double, stage: String) {
        self.fraction = fraction
        self.stage = stage
    }
}

/// The proposed, uncommitted result of a solve. `mesh` is a fresh handle; the
/// live document is untouched until the ghost is accepted. `addedFaces` are the
/// faces the solve created (for a whole-mesh remesh, every face of `mesh`).
public struct SolverGhost {
    public let mesh: Mesh
    public let addedFaces: [UInt32]

    /// Region solves only; empty for `.wholeMesh`. Interface vertices are
    /// guaranteed to be present in `mesh` under the same ids at bitwise
    /// identical positions — the engine refuses to publish a solve otherwise.
    public let interfaceVertices: [UInt32]

    /// Interface vertices whose valence differs from the surrounding cage's
    /// prescription. **Not an error, and not guaranteed empty.** Forcing it to
    /// zero is a coupled degree-constrained matching over the interface ring
    /// that no local pass solves; it is tracked as task 5.3a. Surface it, do
    /// not assert on it.
    public let interfaceIrregular: [UInt32]

    /// Non-quads touching the interface.
    public let residualTriangles: Int

    /// Predicted interior singularity budget implied by the boundary charge.
    public let interiorIndexBudget: Int

    public init(
        mesh: Mesh,
        addedFaces: [UInt32],
        interfaceVertices: [UInt32] = [],
        interfaceIrregular: [UInt32] = [],
        residualTriangles: Int = 0,
        interiorIndexBudget: Int = 0
    ) {
        self.mesh = mesh
        self.addedFaces = addedFaces
        self.interfaceVertices = interfaceVertices
        self.interfaceIrregular = interfaceIrregular
        self.residualTriangles = residualTriangles
        self.interiorIndexBudget = interiorIndexBudget
    }
}

/// A single Weave solve. Backends: `EngineRemeshSolver` now (auto-retopology),
/// the constraint-aware engine solver later — swapped behind this protocol with
/// no change to the app, ghost pipeline, or tests above it.
///
/// Contract:
/// - Deterministic: identical (source, region, constraints, params) → an
///   identical ghost.
/// - Non-mutating: the solve never modifies `source`.
/// - Cancellable: `isCancelled` is polled; when it returns `true` the solve
///   stops and returns `nil`, having produced nothing.
public protocol WeaveSolving: Sendable {
    func solve(
        source: Mesh,
        region: SolveRegion,
        constraints: WeaveConstraints,
        params: SolverParameters,
        onProgress: ((SolverProgress) -> Void)?,
        isCancelled: () -> Bool
    ) throws -> SolverGhost?
}

/// The first `WeaveSolving` backend: the engine's auto-retopology
/// (`cyber_remesh`). Solves a whole-mesh region by remeshing the source into a
/// fresh quad mesh, forwarding progress and cancellation. It accepts but does
/// NOT honour the field constraints — that is the constraint-aware backend's job.
public struct EngineRemeshSolver: WeaveSolving {
    public init() {}

    public func solve(
        source: Mesh,
        region: SolveRegion,
        constraints: WeaveConstraints,
        params: SolverParameters,
        onProgress: ((SolverProgress) -> Void)?,
        isCancelled: () -> Bool
    ) throws -> SolverGhost? {
        // A region solve remeshes a CARVED COPY of the source: everything
        // outside the region is deleted, and the existing whole-mesh remesher
        // then produces a cage covering exactly the painted area, with its own
        // open boundary (openspec add-painted-region-retopo).
        //
        // Carving rather than teaching the remesher about regions is what makes
        // this need no engine change — and it is honest about the result: the
        // solver genuinely sees a smaller model, so its density, boundaries and
        // cancellation all behave exactly as they do for a whole mesh.
        let carve = try Self.carved(source, to: region)
        let source = carve.mesh
        // Density: the density constraint scales the edge length (finer edge →
        // smaller scale) on top of the params' quad budget.
        var remeshParams = params.remesh
        // The quad budget follows the painted SHARE. A budget is a statement
        // about the whole model ("about 1500 quads for this bunny"), so applying
        // it unscaled to a patch asks for the entire model's topology inside one
        // haunch: measured, a 12-face carve at the raw 50 000-quad default did
        // not finish inside a minute. Painting a tenth of the Target now asks for
        // about a tenth of the quads.
        if carve.share < 1 {
            remeshParams.targetQuads = max(4, Int((Float(remeshParams.targetQuads) * carve.share).rounded()))
        }
        if let density = constraints.density {
            remeshParams.edgeScale = Self.edgeScale(for: density, base: remeshParams.edgeScale)
        }
        // Guide strokes + tagged loops → orientation guides that steer the cross
        // field so edge flow follows them (add-weave-guide-field-steering). Set
        // on the source handle; the engine reads them in the remesh below.
        let (guidePoints, guideDirs) = Self.orientationGuides(from: constraints, source: source)
        try source.setOrientationGuides(points: guidePoints, directions: guideDirs)
        // `withoutActuallyEscaping`: the engine invokes `isCancelled`
        // synchronously during the call, but the parameter is non-escaping.
        let ghostMesh = try withoutActuallyEscaping(isCancelled) { cancel -> Mesh? in
            try source.remeshed(
                parameters: remeshParams,
                onProgress: onProgress.map { report in
                    { fraction, stage in report(SolverProgress(fraction: Double(fraction), stage: stage)) }
                },
                isCancelled: cancel
            )
        }
        guard let ghostMesh else { return nil }  // cancelled
        // Symmetry: clip the fresh cage to the working domain and replicate it, so the
        // output is symmetric about every enabled plane AND every radial sector.
        if let symmetry = constraints.symmetry, symmetry.isEnabled, symmetry.isActive {
            try Self.makeSymmetric(ghostMesh, settings: symmetry)
        }
        return SolverGhost(mesh: ghostMesh, addedFaces: ghostMesh.liveFaceIDs())
    }

    /// Builds world-space orientation guide samples from the flow constraints:
    /// each guide stroke and each tagged loop becomes a run of (midpoint,
    /// tangent) samples along its polyline / edge chain. Tagged-loop edges are
    /// resolved to world positions through `source` (the mesh they index).
    private static func orientationGuides(
        from constraints: WeaveConstraints, source: Mesh
    ) -> (points: [SIMD3<Float>], directions: [SIMD3<Float>]) {
        var points: [SIMD3<Float>] = []
        var directions: [SIMD3<Float>] = []

        func addSegment(_ a: SIMD3<Float>, _ b: SIMD3<Float>) {
            let d = b - a
            let len = simd_length(d)
            guard len > 1e-9 else { return }
            points.append((a + b) * 0.5)
            directions.append(d / len)
        }

        // Guide strokes carry world points directly.
        for stroke in constraints.guideStrokes where stroke.points.count >= 2 {
            for i in 0..<(stroke.points.count - 1) {
                addSegment(stroke.points[i], stroke.points[i + 1])
            }
        }
        // Tagged loops index edges of `source`; resolve each to its endpoints.
        for loop in constraints.taggedLoops {
            for edge in loop.edges {
                guard let ends = source.edgeEndpoints(of: edge),
                    let a = source.vertexPosition(ends.0),
                    let b = source.vertexPosition(ends.1)
                else { continue }
                addSegment(a, b)
            }
        }
        return (points, directions)
    }

    /// Maps a density field's target edge length onto the remesher's edge scale:
    /// a finer edge shrinks the scale. Clamped to a sane range so a stray value
    /// cannot make the remesh degenerate or runaway.
    /// The source restricted to `region`: a duplicate with every face outside
    /// the region removed. `.wholeMesh` hands back the source untouched.
    ///
    /// Refuses an empty region and one naming every live face — the first has
    /// nothing to solve, and the second is a whole-mesh solve wearing a disguise,
    /// which would hide a selection bug rather than report it. Dead ids are
    /// IGNORED: a Target can be reloaded under a stale selection, and that is not
    /// worth failing a solve over.
    /// A carved solve domain: the mesh to remesh, and what FRACTION of the
    /// source's faces it kept (1 for a whole-mesh solve).
    public struct Carve {
        public let mesh: Mesh
        public let share: Float
    }

    public static func carved(_ source: Mesh, to region: SolveRegion) throws -> Carve {
        guard case .faces(let faces) = region else { return Carve(mesh: source, share: 1) }
        let live = Set(source.liveFaceIDs())
        let keep = Set(faces).intersection(live)
        guard !keep.isEmpty else {
            throw CyberKitError(
                code: .invalidArgument, message: "the region names no live face of the Target"
            )
        }
        guard keep.count < live.count else {
            throw CyberKitError(
                code: .invalidArgument,
                message: "the region names every face — run a whole-mesh solve instead"
            )
        }
        let carved = try source.duplicated()
        try carved.deleteFaces(Array(live.subtracting(keep)))
        return Carve(mesh: carved, share: Float(keep.count) / Float(live.count))
    }

    private static func edgeScale(for density: DensityField, base: Float) -> Float {
        guard density.targetEdgeLength > 0 else { return base }
        return min(max(base * density.targetEdgeLength, 0.05), 100)
    }

    /// Makes `cage` mirror-symmetric about EVERY enabled mirror axis: keep only the
    /// faces wholly inside the working orthant (delete any face with a vertex on the
    /// far side of ANY enabled plane), snap each seam onto its plane, then reflect +
    /// weld — so the kept wedge is mirrored into all `2^n` subsets and the result is
    /// symmetric about every plane at once.
    ///
    /// Clipping by whole-face (not centroid) is what makes it symmetric: a face
    /// straddling a plane is not wholly on the working side, so `applySymmetry` would
    /// leave it un-mirrored.
    ///
    /// Multi-axis needs no new mirroring machinery — `applySymmetry(_:snapping:)`
    /// already reduces over `mirrorAxes` and mirrors a quadrant into all four. The
    /// only thing that was single-axis was this CLIP, which is why the axes had to
    /// become an intersection of half-spaces rather than one.
    ///
    /// Mutates `cage` (a fresh remesh handle — never the source).
    private static func makeSymmetric(_ cage: Mesh, settings: SymmetrySettings) throws {
        let axes = settings.mirrorAxes
        let sectors = settings.radialCount
        let origin = settings.origin

        // The working DOMAIN is the intersection of the mirror orthant and the radial
        // sector. Clipping to the intersection first — rather than mirroring and then
        // sector-clipping, or vice versa — is what makes the two compose: each
        // replication step then fills a domain the other has not already populated.
        // Mirroring first and clipping after would throw away most of what it built.
        func outsideDomain(_ vertex: UInt32) -> Bool {
            guard let position = cage.vertexPosition(vertex) else { return false }
            let local = position - origin
            for axis in axes {
                let side = simd_dot(local, axis.normal)
                if settings.workingSidePositive ? side < 0 : side > 0 { return true }
            }
            if sectors > 1, let angle = Self.sectorAngle(local, axis: settings.radialAxis) {
                // [0, 2pi/N) is the authored wedge. A vertex ON the axis has no angle and
                // belongs to every sector, so `sectorAngle` returns nil for it and it is
                // never clipped — otherwise the centre would be deleted from its own cage.
                if angle >= 2 * Float.pi / Float(sectors) { return true }
            }
            return false
        }

        var doomed: [UInt32] = []
        for face in cage.liveFaceIDs()
        where cage.faceVertices(face).contains(where: outsideDomain) {
            doomed.append(face)
        }
        // Nothing to replicate if the clip would empty the cage — leave it as-is.
        // (Preserved from the single-axis version, including that an already-clipped
        // cage is left alone rather than replicated.)
        guard !doomed.isEmpty, doomed.count < cage.faceCount else { return }
        _ = try cage.deleteFaces(doomed)

        // RADIAL first: rotation does not commute with reflection in general, and doing
        // it inside the un-mirrored wedge means each mirror afterwards reflects a
        // complete radial fan rather than a partial one.
        if sectors > 1 {
            try Self.replicateRadially(cage, settings: settings)
        }
        // Snap each seam onto its OWN plane before mirroring, so a vertex sitting on
        // two planes — the orthant's edge — is welded onto both rather than one.
        for axis in axes {
            _ = try cage.snapToSymmetryPlane(settings, axis: axis)
        }
        if !axes.isEmpty {
            _ = try cage.applySymmetry(settings)
        }
    }

    /// Angle of `local` about `axis`, in [0, 2pi), or nil when the point lies ON the
    /// axis and therefore has no meaningful angle.
    private static func sectorAngle(
        _ local: SIMD3<Float>, axis: SymmetrySettings.Axis
    ) -> Float? {
        let normal = axis.normal
        // Two axis-perpendicular basis vectors, so the angle is measured consistently.
        let reference: SIMD3<Float> = abs(normal.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
        let u = simd_normalize(reference - normal * simd_dot(reference, normal))
        let v = simd_cross(normal, u)
        let planar = local - normal * simd_dot(local, normal)
        guard simd_length(planar) > 1e-6 else { return nil }  // on the axis
        let angle = atan2(simd_dot(planar, v), simd_dot(planar, u))
        return angle < 0 ? angle + 2 * Float.pi : angle
    }

    /// Fills the remaining sectors by rotating the authored wedge about the radial axis,
    /// then welding the seams so the result is MANIFOLD rather than abutting shells.
    ///
    /// Built from `createFace` on rotated world points rather than an engine op: radial
    /// replication has no engine primitive (mirroring does), and a sector's face count is
    /// small enough that constructing them is not worth an engine change to avoid.
    private static func replicateRadially(_ cage: Mesh, settings: SymmetrySettings) throws {
        let sectors = settings.radialCount
        let normal = settings.radialAxis.normal
        let origin = settings.origin
        // Snapshot BEFORE adding anything: replicating the growing mesh would
        // re-replicate what it just created, N times over.
        let source: [[SIMD3<Float>]] = cage.liveFaceIDs().compactMap { face in
            let ring = cage.faceVertices(face).compactMap { cage.vertexPosition($0) }
            return ring.count >= 3 ? ring : nil
        }
        guard !source.isEmpty else { return }

        for step in 1..<sectors {
            let angle = 2 * Float.pi * Float(step) / Float(sectors)
            let rotation = simd_quatf(angle: angle, axis: normal)
            for ring in source {
                let rotated = ring.map { origin + rotation.act($0 - origin) }
                // A face that fails to build is skipped rather than aborting the whole
                // replication: a partial fan is recoverable, a thrown-away solve is not.
                _ = try? cage.createFace(at: rotated)
            }
        }
        // Close the seams the replication left. Scene-scaled tolerance, matching the
        // bake path: only ALREADY-coincident vertices merge, so nothing visibly moves.
        _ = try? cage.rotationalWeld(
            sectorCount: sectors, tolerance: settings.weldTolerance
        )
    }
}

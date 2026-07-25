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

/// The region a solve operates over. A whole-mesh solve is the maximal region
/// ("solve all"); a face sub-region is reserved for the constraint-aware solver.
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
    public var targetEdgeLength: Float
    public init(targetEdgeLength: Float) { self.targetEdgeLength = targetEdgeLength }
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

    public init(
        frozenFaces: [UInt32] = [],
        taggedLoops: [TaggedLoop] = [],
        guideStrokes: [GuideStroke] = [],
        pinnedVertices: [UInt32] = [],
        density: DensityField? = nil,
        symmetry: SymmetrySettings? = nil
    ) {
        self.frozenFaces = frozenFaces
        self.taggedLoops = taggedLoops
        self.guideStrokes = guideStrokes
        self.pinnedVertices = pinnedVertices
        self.density = density
        self.symmetry = symmetry
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
    public init(mesh: Mesh, addedFaces: [UInt32]) {
        self.mesh = mesh
        self.addedFaces = addedFaces
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
        guard case .wholeMesh = region else {
            // Sub-region solve is the constraint-aware backend's job; fail
            // clearly so callers rely on `.wholeMesh` this slice.
            throw CyberKitError(code: .invalidArgument, message: "EngineRemeshSolver supports only .wholeMesh")
        }
        // Density: the density constraint scales the edge length (finer edge →
        // smaller scale) on top of the params' quad budget.
        var remeshParams = params.remesh
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
        // Symmetry: clip the fresh cage to the working side and mirror it, so
        // the output is exactly symmetric about the plane. Only the first mirror
        // axis is honoured this slice (multi-axis / radial are deferred).
        if let symmetry = constraints.symmetry, symmetry.isEnabled,
            let axis = symmetry.mirrorAxes.first {
            try Self.makeSymmetric(ghostMesh, settings: symmetry, axis: axis)
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
    private static func edgeScale(for density: DensityField, base: Float) -> Float {
        guard density.targetEdgeLength > 0 else { return base }
        return min(max(base * density.targetEdgeLength, 0.05), 100)
    }

    /// Makes `cage` mirror-symmetric about `axis`: keep only the faces WHOLLY on
    /// the working side (delete any face with a vertex on the far side), snap the
    /// seam onto the plane, then reflect + weld the working side — so every kept
    /// face is mirrored and the result is symmetric. Clipping by whole-face
    /// (not centroid) is what makes it symmetric: a face straddling the plane is
    /// not "wholly on the working side", so `applySymmetry` would leave it
    /// un-mirrored. Mutates `cage` (a fresh remesh handle — never the source).
    private static func makeSymmetric(
        _ cage: Mesh, settings: SymmetrySettings, axis: SymmetrySettings.Axis
    ) throws {
        let normal = axis.normal
        let origin = settings.origin
        func onFarSide(_ vertex: UInt32) -> Bool {
            guard let position = cage.vertexPosition(vertex) else { return false }
            let side = simd_dot(position - origin, normal)
            return settings.workingSidePositive ? side < 0 : side > 0
        }
        var doomed: [UInt32] = []
        for face in cage.liveFaceIDs()
        where cage.faceVertices(face).contains(where: onFarSide) {
            doomed.append(face)
        }
        // Nothing to mirror if the clip would empty the cage — leave it as-is.
        guard !doomed.isEmpty, doomed.count < cage.faceCount else { return }
        _ = try cage.deleteFaces(doomed)
        _ = try cage.snapToSymmetryPlane(settings, axis: axis)
        _ = try cage.applySymmetry(settings, axis: axis)
    }
}

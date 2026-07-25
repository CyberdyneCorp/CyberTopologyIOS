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
public protocol WeaveSolving {
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
        // `withoutActuallyEscaping`: the engine invokes `isCancelled`
        // synchronously during the call, but the parameter is non-escaping.
        let ghostMesh = try withoutActuallyEscaping(isCancelled) { cancel -> Mesh? in
            try source.remeshed(
                parameters: params.remesh,
                onProgress: onProgress.map { report in
                    { fraction, stage in report(SolverProgress(fraction: Double(fraction), stage: stage)) }
                },
                isCancelled: cancel
            )
        }
        guard let ghostMesh else { return nil }  // cancelled
        let addedFaces = ghostMesh.liveFaceIDs()
        return SolverGhost(mesh: ghostMesh, addedFaces: addedFaces)
    }
}

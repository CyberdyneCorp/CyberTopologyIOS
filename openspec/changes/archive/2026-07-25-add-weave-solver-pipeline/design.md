# Design: add-weave-solver-pipeline

## Context

The Weave solver (Phase 5) is the app's differentiator. Per `add-cybertopology-app`
decision **D3**, the engine exposes `solve(region, constraints, params) → ghost mesh`
with progress + cancellation and strict determinism; "solve all" is a maximal region.
Per **D1**, no mesh algorithms live in Swift — CyberKit is a typed façade over C++.

The pinned engine (v0.2.4) has no *constraint-aware* solver, but it DOES ship
`cyber_remesh` — a full auto-retopology solver with `(in, params, progress, cancel →
out)`, which is exactly a Weave solver session over a maximal region with no field
constraints. This change surfaces that as the first backend, freezing the Weave API
so the constraint-aware engine solver can drop in later behind an unchanged surface.

## Goals / Non-Goals

**Goals:** a complete, cancellable solve→ghost→accept pipeline with a stable API;
real auto-retopology output (not placeholder); opt-in; source never mutated until
accept; accepted output is ordinary EditMesh; the Phase 4 device+simulator test bar.

**Non-Goals:** the constraint-aware solver, field-constraint honouring, the
prescribed-boundary guarantee, regional/sub-region solve, implicit sizing, ambient
assist, benchmarks. All deferred to the engine follow-up.

## API surface (CyberKit, new)

```swift
enum SolveRegion: Equatable { case wholeMesh; case faces([UInt32]) }  // v1 uses wholeMesh

struct WeaveConstraints: Equatable, Codable {          // full taxonomy; forward-compatible
    var frozenFaces: [UInt32] = []
    var taggedLoops: [TaggedLoop] = []
    var guideStrokes: [GuideStroke] = []
    var pinnedVertices: [UInt32] = []
    var density: DensityField? = nil
    var symmetry: SymmetrySettings? = nil
}

struct SolverParameters: Equatable, Codable {
    var remesh: RemeshParameters = RemeshParameters()  // targetQuads, adaptivity, method…
    var seed: UInt64 = 0
}

struct SolverGhost { var mesh: Mesh; var addedFaces: [UInt32] }
struct SolverProgress: Equatable { var fraction: Double; var stage: String }

protocol WeaveSolving {
    func solve(
        target: Mesh, region: SolveRegion, constraints: WeaveConstraints,
        params: SolverParameters,
        onProgress: ((SolverProgress) -> Void)?, isCancelled: () -> Bool
    ) throws -> SolverGhost?
}

struct EngineRemeshSolver: WeaveSolving { /* wraps cyber_remesh via Mesh.remeshed */ }
```

## Key decisions

### D1 — `WeaveSolving` protocol is the swap seam
The app, ghost pipeline, accept flow, and tests depend only on `WeaveSolving` + the
value types. This change wires `EngineRemeshSolver`; the engine follow-up adds a
`ConstraintWeaveSolver` and swaps the injected instance. Nothing above the protocol
changes — that is the entire reason to fix the API here first.

### D2 — First backend: `EngineRemeshSolver` over `cyber_remesh`
`Mesh.remeshed(...)` is extended to forward the engine's `CyberProgressCb` /
`CyberCancelCb` (today NULL) to `onProgress` / `isCancelled`. `EngineRemeshSolver`
runs the remesher on the `target` (a maximal-region "solve all"), producing a fresh
quad EditMesh returned as the ghost (`addedFaces` = all of it — it is a fresh mesh,
not an edit of existing topology). It ignores the field constraints in
`WeaveConstraints` for now. The remesh never mutates its input (verified by the
existing `remeshCube` test), so "source untouched until accept" holds intrinsically.

### D3 — Ghost + accept reuses the camera-tool session shape
`MeshEditController` already runs `CameraToolSession` with `previewPositions/Normals/
Indices` rendered by `GhostRenderPath` and committed by `commitCameraToolSession()`.
The Auto-Retopo session mirrors this: hold the `SolverGhost`, render it with the amber
`GhostStyle` reserved for "Weave-proposal ghosts", and on accept commit it as the
EditMesh in one journaled edit (create-or-replace, since a maximal solve produces a
whole new cage). Cancel/draw-over discards with no journal entry. Accepted geometry is
ordinary EditMesh.

### D4 — Determinism: required by contract, verified for this backend
Determinism (same inputs → bit-identical ghost) is a mandated Weave property (D3:
"fixed seeds, ordered reductions, no wall-clock dependence"). It is currently
UNVERIFIED for `cyber_remesh` (the existing test only checks it produces quads). Task
5.x runs the remesher twice on the same input+params and compares the payloads. If it
is not bit-deterministic (e.g. an unseeded field-alignment init), that is filed as an
engine issue against the D3 contract — the spec is not weakened, because a
non-deterministic solver is an engine defect, not an acceptable pipeline state. Worst
case, the slice ships with the requirement flagged pending the engine fix.

### D5 — Test hosting follows the Phase 4 device pattern
Solver/remesh tests use public CyberKit API + inline fixtures (no `#filePath`
goldens in the shared path) so they run in BOTH tool-hosted `CyberKitTests`
(simulator) and, compiled into `CyberTopologyTests`, on device. Ghost accept/discard
tests are app-hosted (device + simulator).

## Risks / Trade-offs

- **`cyber_remesh` determinism unverified** → explicit verify task (D4); a real risk,
  handled honestly rather than assumed.
- **Whole-Target only (no sub-region)** → acceptable: "solve all" is the maximal
  region per D3, and it is the highest-value one-tap path. Regional solve arrives with
  the constraint-aware backend.
- **Constraints stored but not honoured could mislead** → the spec is explicit that
  only the session/ghost/accept/opt-in/determinism properties are guaranteed this
  change; field honouring is a named non-goal.
- **API churn when the engine lands** → mitigated by modelling all six constraint
  kinds now, so the engine change ADDS honouring, not new surface.

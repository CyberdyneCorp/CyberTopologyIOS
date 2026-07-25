# Proposal: add-weave-guide-field-steering

## Why

The Weave solver honours density and symmetry, but the four constraints that
actually *steer edge flow* — guide strokes, tagged-loop flow, frozen patches,
pins — are still ignored. A feasibility study of the `CyberRemesherAndUV` engine
found that the hard part is NOT a missing solver: the engine already has a
complete field-aligned quadrangulation stack (a 4-RoSy cross field, an
Instant-Meshes position field, a native seamless/MIQ solver, multiple quad
extractors) behind an injectable `IQuadrangulator` seam. Quad flow is a pure
function of the cross field — bend the field and the quads follow.

The load-bearing gap is that the cross-field solve accepts orientation
constraints ONLY from geometric feature/boundary edges: there is no channel for
a caller to inject a direction. The per-node `constrained[]`/`constraintDir[]`
machinery that pins feature edges is exactly the right injection point, but
nothing plumbs external directions into it, and the render-only
`cyber_mesh_set_tagged_edges` never reaches the solver.

This change opens that channel: a caller can pass per-element directional
constraints (a world-space tangent + weight) that bias the cross field, so
Auto-Retopo edge flow follows guide strokes and tagged loops. It uses the
existing pin-and-relax mechanism (hard pins first), so it needs NO new solver
math — it unlocks two of the four flow constraints at once.

## What Changes

- **Engine (cross field):** `computeCrossField` / `computeCrossFieldFromOrientation`
  gain a `CrossFieldConstraints` input — a list of `{faceId, worldDir, weight}`
  merged into the existing `constrained[]`/`constraintDir[]` arrays before
  smoothing (each world direction projected into the face's tangent frame and
  seeded as the target `e^{i4θ}`). Hard-pin this change; soft/weighted is deferred.
- **Engine (seam + pipeline):** the constraints thread from `pipeline::remesh`
  down through the `IQuadrangulator` seam to the cross-field solve, remapped
  per-island (the pipeline splits the input into islands and quadrangulates each).
  The field-aligned quadrangulator (which consumes `computeCrossField` directly)
  is the first consumer.
- **CAPI:** a new entry to carry the guides — orientation guides attached to the
  mesh handle (like tagged edges) or a `cyber_remesh_with_constraints` variant —
  taking face ids + directions.
- **CyberKit:** a typed guide-constraint API; `EngineRemeshSolver` maps
  `WeaveConstraints.guideStrokes` and `.taggedLoops` onto per-face directions and
  passes them through.
- **App:** the Auto-Retopo path threads any active guide strokes / tagged loops
  from the document into the solve.

## Impact

- Affected specs: `weave-solver` (ADDED: the solver honours guide-stroke and
  tagged-loop orientation; edge flow follows the guide direction).
- Affected code: engine `crossfield.{hpp,cpp}`, `field_quadrangulator.cpp`,
  `quadrangulate.hpp`, `pipeline.{hpp,cpp}`, `remesh_params.hpp`, `capi.{h,cpp}`
  (delivered as `Engine/patches/0003-*.patch`); CyberKit `WeaveSolver.swift` +
  a guides wrapper; app `AutoRetopoSession.swift`.
- Affected tests: engine-level (a guide along one axis makes cross-field-aligned
  output flow along it), CyberKit solver tests, app-hosted guide threading.

## Non-Goals

- **Soft / weighted constraints** — guide strokes usually want a soft bias with
  controlled singularity placement near stroke endpoints; this change hard-pins.
  Weighted least-squares in the relaxation is a follow-on.
- **Frozen patches, pins-as-boundary-conditions, regional solve, and the
  prescribed-boundary guarantee** — these bottleneck on the research-grade
  prescribed-boundary integer-grid solve, out of scope here.
- Steering the QuadCover/seamless-MIQ path — this change targets the
  field-aligned quadrangulator, which consumes the cross field directly.

## Notes

This is the first change that edits the engine submodule (a new patch in the
2-patch stack). It reuses the engine's proven pin-and-relax field machinery, so
the risk is in plumbing and tuning, not new algorithms. When soft constraints and
the prescribed-boundary solve land later, they extend the same injection channel.

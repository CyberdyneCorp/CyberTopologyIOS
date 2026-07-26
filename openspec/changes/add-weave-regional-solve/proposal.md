# Proposal: add-weave-regional-solve

## Why

`SolveRegion.faces` is declared (`CyberKit/Sources/CyberKit/WeaveSolver.swift:18`) and
immediately rejected: `guard case .wholeMesh = region else { throw CyberKitError(code:
.invalidArgument, ...) }` at `WeaveSolver.swift:171-174`, pinned by the test at
`CyberKit/Tests/CyberKitTests/WeaveSolverTests.swift:332`. The only backend is
`EngineRemeshSolver`, which wraps the whole-mesh `cyber_remesh` (`capi.cpp:261`).

That one gap is the shared blocker behind five open tasks, exactly as
`openspec/changes/add-cybertopology-app/tasks.md` already records: 5.1a's region
support, 5.2a's EditMesh-sourced constraints, 5.3 in full, 5.4a's lasso UX and live
re-solve, and 5.5a's implicit sizing. `WeaveConstraints.frozenFaces`
(`WeaveSolver.swift:53`) is Codable-persisted and never read — the solve body consumes
only `density`, `guideStrokes`, `taggedLoops` and `symmetry`.

Task 5.3 — the prescribed-boundary guarantee, the differentiator and the v0.2 gate — is
not merely unimplemented, it is currently **inexpressible**. Four facts, each verified
in the engine source:

1. **A region boundary cannot be enumerated.** `cyber::retopo::boundaryChain`
   (`retopo/boundary.hpp:63`) and `cyber_mesh_boundary_loop` rest on `isBoundaryEdge ==
   "edgeFaces(e).size() == 1"`. Every edge of a region embedded in frozen topology has
   TWO incident faces, so the walk returns empty.
2. **The pipeline destroys the caller's ids before a region could be used.**
   `pipeline.cpp:527-529` runs `triangulate()`, `weldCoincidentVertices()` and
   `orientFacesConsistently()`; then `extractIsland` renumbers again through
   `Mesh::fromIndexed`, PER ISLAND, at `pipeline.cpp:605`. This is exactly why patch
   0003 had to make orientation guides world-space rather than face-id-based.
3. **One stage silently resamples a prescribed boundary.** `SplitPass::run`
   (`isotropic.cpp:140-168`) calls `splitEdge(e, 0.5f)` on any over-long edge with NO
   feature or boundary guard — while CollapsePass (`:209-212`), FlipPass (`:253`) and
   SmoothAndProjectPass (`:318`) all refuse feature elements. So prescribed vertices
   survive but the prescribed EDGE SET does not, and the boundary stays geometrically
   on the prescribed polyline: **a positional or Hausdorff assertion passes while
   vertex identity fails.**
4. **The default quad backend cannot honour a prescription at all.** quad-cover is the
   C API default (`capi.cpp:258`) and ends with `mesh = std::move(quads)`
   (`quadcover_extractor.cpp:2512`); instant-meshes (`quad_extract.cpp:886`) and
   integer (`:1047`) do the same. Zero input vertices survive. Only the field-aligned
   extractor is vertex-preserving.

So "quads land exactly on the prescribed boundary" today has no mechanism, no oracle
and no test. This change builds the mechanism, and builds it so the guarantee is a
property of the shipped code rather than of an audit.

## What Changes

- **Engine: a `RegionSolve` mask pair (new files, zero patch conflict).**
  `core/region_solve.{hpp,cpp}` — `buildRegionSolve()` derives, from a caller-supplied
  face set: a per-`FaceId` `frozenFace` mask, a per-`VertexId` `vertexPinned` mask, the
  ordered interface loops, a per-interface-vertex valence prescription, and a pre-solve
  feasibility budget.
- **Engine: the interface becomes feature edges, so existing freeze machinery becomes a
  region scope for free.** After `tagFeatureEdges` (which OVERWRITES every alive edge's
  flag — `mesh_diagnostics.cpp:182-203`, so ordering is load-bearing), force
  `setFeatureEdge(e, true)` on every edge incident to a frozen face. That single act
  recruits six already-shipping guards: CollapsePass, FlipPass, SmoothAndProjectPass,
  `collectPairEdges`, `removeDoublets` and `eligibleVertex` — plus the exact Dirichlet
  cross-field pin (`crossfield.cpp:83`, `:186-189`).
- **Engine: exactly ONE behavioural patch to an existing pass.** Four lines in
  `SplitPass::run` after `isotropic.cpp:147`. This is the only pass in the engine that
  inserts a vertex into a prescribed boundary polyline. Keyed on the pin mask (not on
  `edgeFaceCount == 1`) so it works for an interior interface, and a strict no-op when
  `region == nullptr`.
- **Engine: a region branch in `cyber::remesh::remesh`, entirely behind `if
  (!region.empty())`.** Skips triangulate/weld/orient, islands/extractIsland,
  `applySmallPatchPolicy`, the stage-3 `fromIndexed` merge, `fillHoles` and the whole
  `pureQuads` block. Scopes `totalSurfaceArea` to active faces so `targetEdgeLength` is
  region-local. Output is `std::move(work)` — the input mesh with the region rewritten
  in place, ids intact.
- **Engine: a HARD conformance gate.** `verifyInterfaceConformance()` runs after
  quadrangulation and before publication, checking per-vertex interface regularity, the
  discrete index identity, and that no triangle touches the interface. On any failure it
  returns `RunStatus::Error` naming the offending vertices — **no ghost is emitted.**
- **Engine C API:** `cyber_mesh_set_solve_region` (handle side-channel, the patch-0003
  precedent), `cyber_mesh_solved_faces`, `cyber_mesh_interface_vertices`,
  `cyber_mesh_vertex_face_count` (the valence primitive, verified absent), and
  `cyber_mesh_duplicate` (an ID-PRESERVING clone; today the only cross-ABI mesh copy is
  a `payloadData` OBJ round-trip, which renumbers).
- **CyberKit: the region backend lands as a SECOND `WeaveSolving` conformance.**
  `RegionWeaveSolver` plus a dispatching `CompositeWeaveSolver`. The guard at
  `WeaveSolver.swift:171` is deliberately KEPT — the protocol doc at `:133-142` already
  promises exactly this swap, and keeping it makes a whole-mesh regression structurally
  impossible.
- **App:** `beginAutoRetopo` gains a `region:` parameter defaulting to `.wholeMesh`.

## Impact

- Affected specs: `weave-solver` (MODIFIED: solver-session API region support; ADDED:
  prescribed-boundary landing, interior-only singularities, enforce-or-fail refusal,
  region-solve id stability).
- Affected code:
  - Engine (`Engine/patches/0006-cybertopology-regional-prescribed-boundary-solve.patch`):
    new `core/region_solve.{hpp,cpp}` and `core/interface_conformance.{hpp,cpp}`;
    edits to `pipeline.{cpp,hpp}`, `isotropic.{cpp,hpp}`, `remesh_params.{hpp,cpp}`,
    `retopo/boundary.hpp` (additive), `field_quadrangulator.{cpp,hpp}`, `capi.cpp`,
    `cyber_capi.h`. Deliberately does NOT touch `crossfield.{cpp,hpp}`,
    `quadrangulate.hpp` or `mesh.hpp`.
  - CyberKit: region primitives on `Mesh`/`MeshAnnotations`, `RegionWeaveSolver`,
    `CompositeWeaveSolver`, additive `SolverGhost` fields.
  - App: `AutoRetopoSession.beginAutoRetopo(region:)`; banner surfaces
    `residualTriangles` and rejection reasons.
- Affected tests: new engine `tests/core/test_region_solve.cpp`; CyberKit 5.3 proof
  suite asserting against the LIVE ghost handle (never `payloadData()`); a new float-free
  `*.interface.golden` format; a null-object regression proving every existing golden is
  byte-identical.

## Non-Goals (deferred)

- **Construct-correct interior singularity placement.** This change delivers
  enforce-or-fail (a violating ghost cannot exist), not construct-correct (a conforming
  ghost always exists). Some regions will produce no ghost. Split out as 5.3a.
- **Prescribed interior cone placement** — the caller cannot yet say "put a pole here".
- **Multi-loop strong guarantee.** Multi-loop, pinched and holed regions work
  mechanically, but the interior-index claim degrades to per-loop parity. The spec says
  so; the marketing claim must not outrun the disk case.
- **Regional lasso UX and live re-solve (5.4a)**, implicit sizing beyond the
  prescribed-spacing derivation (5.5a), ambient assist (5.6), benchmark (5.7).
- **Whole-mesh repair in region mode.** `weldCoincidentVertices` and
  `orientFacesConsistently` cannot run (they renumber), so unwelded or
  inconsistently-wound imports are REFUSED up front rather than silently corrupted. The
  app has no weld affordance today; that gap is named, not closed.

## Notes

Whole-mesh regression safety is a property of the code, not of an audit:
`RegionSolve::empty()` short-circuits every branch, and `region = {}` is a defaulted
trailing parameter, so `.wholeMesh` executes today's code byte-for-byte.

The brief that produced this design asked to extend patch 0003's `CrossFieldConstraint`
mechanism "from soft seeds to hard constraints". That premise is wrong and the design
does not follow it: `crossfield.cpp:186-189` (`if (constrained[c]) { continue; }`) never
writes pinned faces back, so the seeded `cos/sin(4α)` survives every sweep byte-exact
while still acting as a source column. **The pins are already exact Dirichlet
conditions.** The real defect 0003 left is PRECEDENCE — the guide loop at `:102-119`
unconditionally overwrites a boundary pin. This change fixes precedence by filtering
`projectGuides` rather than by adding a constraint tier to `crossfield.hpp`, which patch
0003 owns, avoiding conflict-surface growth for no behavioural gain.

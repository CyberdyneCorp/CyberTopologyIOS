# Tasks: add-weave-regional-solve

Ordered. **Task 0 was a falsification spike; it ran, it fired, and the change was rescoped
in response (task 0.5).** Read §0 before touching anything else — it is why the conformance
gate has two tiers instead of one, and why 5.3 ships half-closed.

## 0. Falsification spike — RUN 2026-07-26. **FIRED; CHANGE RESCOPED.**

- [x] 0.1 Implemented against the fully-patched engine tree: `frozenFace`/`vertexPinned`
      masks, `setFeatureEdge` interface tagging, the 4-line `SplitPass` guard. No gate, no
      capi, no Swift. Engine tree since reverted to HEAD + 0001..0005 (verified `+1087 -169`,
      matching the patch sum exactly); spike artifacts kept out of the repo.
- [x] 0.2 C++ test over three fixtures — flat 6×6 grid / centre 4×4 region, L-shaped
      region (reflex ring vertex), domed grid ("sphere cap") — solved via `isotropicRemesh`
      + the field-aligned quadrangulator directly, so islands / merge / fillHoles /
      pureQuads are bypassed by construction. Run at 1× (prescribed spacing) and 4× density.
- [x] 0.3 Results.

**(a) and (b) PASS, and the SplitPass guard is load-bearing.** Prescribed positions are
bitwise identical in every configuration — including with the guard OFF, confirming
Invariant P. Frozen face rings are identical with the guard ON. With the guard OFF at 4×:
**20 frozen rings corrupted and 16 interface edges lost.** The four-line patch is
justified by measurement, and G1 (exact landing) holds as designed.

**(c) FAILS on the flat grid, which is the documented stopping condition.**

| fixture | 1× wrong / 16 | 4× wrong / 16 |
|---|---|---|
| grid66_center | **3** | 16 |
| lshape | **4** | 15 |
| sphere_cap | 0 | 16 |

Every 1× failure is the pattern `expected 2 → actual 3`: a mid-side interface vertex ends
with one MORE solved quad than prescribed, total valence 5 — **a new singularity on the
interface.** This reproduces the correctness judge's predicted counterexample exactly,
including the fixture and the number (design.md, "Spine choice").

**The proposed remedy does not work.** A minimal `pairInterfaceRingFirst` (design Stage 5)
was implemented and measured: it performs 11-16 merges and changes the failure count by
**zero** (grid66 3→3, lshape 4→4 at 1×; 16→16 and 15→16 at 4×). The reason is structural,
not an artefact of the spike's simpler scoring: greedy pairing changes WHICH triangles
merge, not how many quads are incident to a given interface vertex. The fan size around a
pinned vertex is fixed by the isotropic stage, and nothing in this design constrains it to
`q_in(b)`. No amount of pairing quality repairs a count.

**Consequence for the gate.** It refuses the whole solve if ANY interface vertex is
non-conforming, so a 3-of-16 per-vertex rate is a **100% solve-rejection rate** on the
simplest possible fixture. Two of three fixtures reject at prescribed density; all three
reject at 4×. That is design risk 1 realised: "this design collapses to the same
narrowness as Design C but with more machinery."

**Caveat, stated honestly.** The spike's ring-first pass runs BEFORE the quadrangulator
rather than inside it between `computeCrossField` and `collectPairEdges`, and scores with
a plain squareness metric rather than the engine's `quadQuality` × field-diagonalness
weight. So this refutes the MECHANISM (greedy interface pairing), not the exact code task
6.3 specifies. Given the count argument above, the exact variant is not expected to differ.

- [x] 0.4 **Round 2 — "constrain it during generation" tested in three cheap forms. All
      three refuted, and the root cause is now understood exactly.**

First, the fan-size hypothesis was WRONG, which is good news buried in a bad result. The
post-isotropic fan is 1-2 triangles short of `2·q_in` on 10-11 of 16 interface vertices,
but a fan of `n` triangles can reach `q` faces whenever `q ≤ n ≤ 2q`, and **every measured
fan satisfies that.** `sphere_cap` proves it directly: 10 "wrong" fans, zero wrong valence.
So the isotropic stage is not the culprit and does not need constraining.

The defect is that no pass ever TARGETS a per-vertex merge count. The face count at an
interface vertex `b` is `n(b) − k(b)`, where `k(b)` is the number of merges across edges
INCIDENT to `b`; conformance needs `k(b) = n(b) − q_in(b)` exactly. So a degree-constrained
pass was implemented (`pairInterfaceByDegree`: per-vertex target, best-quality legal merge,
refusing any merge that would push the far endpoint below ITS target, iterated to a fixed
point), plus a variant that then FREEZES the achieved fan by feature-tagging every edge
incident to an interface vertex so the global pass cannot undo it.

Wrong-valence at prescribed (1×) density, all three fixtures:

| pass | grid66 | lshape | sphere_cap |
|---|---|---|---|
| none (baseline) | 3/16 | 4/16 | 0/16 |
| greedy ring-first | 3/16 | 4/16 | 0/16 |
| degree-constrained | 4/16 | 4/16 | 0/16 |
| degree + fan lock | 3/16 | 3/16 | **3/16** |

**Nothing reaches zero, so the gate rejects every fixture.** Note the last row: locking made
`sphere_cap` WORSE (0 → 3), because its baseline zero was the global pass accidentally
repairing what the interface pass had left — luck, not mechanism.

The decisive measurement is the degree pass judged against its OWN target, before the global
pass runs: **unresolved 3/16 on all three fixtures at 1×, and 15-16/16 at 4×.** It cannot hit
the prescription it is explicitly aiming at.

**Root cause.** Merging across edge `(b,x)` decrements the face count at BOTH endpoints. The
interface vertices are therefore coupled around the ring, and a sequential greedy resolution
deadlocks: at the failing vertices every candidate edge is a feature edge, an interface edge,
or would push a neighbour below its own target. Interface conformance is a **coupled
degree-constrained matching (b-matching) over the interface ring** — a global combinatorial
problem. The engine's matching is blossom-free (`maximumTrianglePairing`,
field_quadrangulator.cpp:195), which the design already noted without drawing this
consequence.

**Revised options.** Option (ii) is refuted in every cheap form. What remains:
      (a) implement a real constrained matching over the interface ring — correct, but a
      substantial new solver and the largest engineering item in the change;
      (b) re-spine on the boundary-staircase lattice (design C), which sidesteps the matching
      entirely by construction, at the cost of a narrower domain;
      (c) relax 5.3 to positional landing only (G1 is proven and nearly free), rewriting the
      spec's interior-singularity requirement rather than deferring it.
**Tasks 1-3 remain validated. Tasks 4-17 stay on hold.**

- [x] 0.5 **DECISION: land 5.1a on the proven foundation; split the singularity guarantee
      out as 5.3a.** Not one of the three options as framed — the framing conflated two
      separable deliverables.

G1 (exact boundary landing) is PROVEN by measurement, and regional solve does not depend on
the singularity guarantee: that is task 5.3's second half, and 5.1a is what four downstream
tasks (5.2a, 5.4a, 5.5a, 5.6) are actually blocked on. So this change now ships regional
solve with exact landing enforced, and interface irregularity MEASURED AND REPORTED rather
than guaranteed or refused.

Concretely, versus the pre-spike plan:
  - the conformance gate splits into a REFUSE tier (exact landing — always achievable, so a
    failure is a regression) and a REPORT tier (irregularity, index residual, interface
    triangles) — task 7;
  - the spec's "Singularities are interior to the solved region" requirement becomes
    "Interface irregularity is measured and reported";
  - test 14.4 asserts the report is CORRECT, not that it is zero;
  - 5.3 closes only for exact landing; **5.3a** carries the guarantee, blocked on a
    constrained-matching solver;
  - the marketing claim that Weave puts no singularity on a prescribed interface is
    unsupported until 5.3a lands, and 5.7 must say so.

Rejected: option (a) now, because a b-matching solver is the largest item in the change and
would block four downstream tasks behind it — it is better sequenced as 5.3a once regional
solve is real and can exercise it. Option (b) for the same reason plus a narrower domain.
Option (c) as literally framed, because "relax 5.3" understates it: the guarantee is not
weakened, it is SPLIT, and the half that is deferred is named with its blocker so it cannot
be quietly forgotten.

## 1. Engine: RegionSolve core (new files, zero patch conflict)

- [x] 1.1 `src/core/include/cyber/core/region_solve.hpp` — `struct RegionSolve` with
      `frozenFace`, `vertexPinned`, `interfaceLoops`, `targetValence`, `indexBudget`,
      `empty()`, `active(FaceId)`, `pinned(VertexId)`. Document Invariants F and P
      inline, citing `mesh.cpp:44-46`/`86-90` and `isotropic.cpp:31-38`.
- [x] 1.2 `src/core/src/region_solve.cpp` — `buildRegionSolve()` per design Stage 2
      (a)-(g), in that exact order; `tagFeatureEdges` BEFORE `setFeatureEdge`
      (`mesh_diagnostics.cpp:182-203` overwrites every alive edge's flag).
- [x] 1.3 Add both to `src/core/CMakeLists.txt`.
- [x] 1.4 Up-front refusals shipped as `RegionSolveStatus` with a distinct reason each:
      `EmptyRegion`, `InvalidFace` (dead / out-of-range / repeated), `WholeMesh` (refused,
      never aliased to the whole-mesh path), `Disconnected`, `CoincidentVertices`,
      `InconsistentWinding`. A refused build leaves the mesh byte-untouched — asserted.

## 2. Engine: region-scoped interface walk

**DEVIATION — the plan specified something impossible.** 2.1 said to put this in
`retopo/boundary.hpp`. It cannot go there: `cyber_retopo` depends on `cyber_core`, and
`buildRegionSolve` lives in core, so core would have to include retopo. The walk therefore
ships as `RegionSolve::isInterfaceEdge` plus the loop walk inside `region_solve.cpp`,
mirroring `detail::nextBoundaryEdge`'s bidirectional walk and its deterministic pinch stop.
A retopo-level wrapper can be added later if 5.4a needs one for interface rendering.

- [x] 2.1 `RegionSolve::isInterfaceEdge` — a live edge with exactly TWO incident faces, of
      which exactly one is in the region. Ordered `interfaceLoops` walked in ascending
      `EdgeId` for determinism.
- [x] 2.2 Asserted: on the interior 4×4 block every interface edge is invisible to
      `retopo::isBoundaryEdge` AND yields an empty `retopo::boundaryChain`, while the region
      walk returns exactly one closed 16-vertex ring.
- [x] 2.3 Cage-derived prescription asserted: 4 block corners require 1 in-region face, 12
      mid-side vertices require 2; a caller override replaces the derived value.

## 3. Engine: the SplitPass guard

- [x] 3.1 `isotropic.hpp` — add `const RegionSolve* region = nullptr;` to
      `IsotropicOptions`, and extend the feature-preservation paragraph at `:16-18`
      (which promises collapse/smooth/flip protection but is silent on splits).
- [x] 3.2 `isotropic.cpp` — immediately after `const auto [a, b] = m_mesh.edgeVertices(e);`
      at `:147`, insert `if (m_options.region && m_options.region->pinned(a) &&
      m_options.region->pinned(b)) { continue; }`, commented as the only vertex-inserting
      pass without a boundary guard. No change to CollapsePass/FlipPass/SmoothAndProjectPass.

## 4. Engine: the pipeline region branch

- [ ] 4.1 `pipeline.hpp` — `remesh()` gains a trailing `const RegionSolve& region = {}`;
      `PipelineResult` gains `solvedFaces`, `interfaceVertices`, `interfaceIssues`,
      `interiorIndexBudget`. Defaulted, so every existing call site compiles unchanged.
- [ ] 4.2 `pipeline.cpp`, all behind `if (!region.empty())`: skip `:527-529`; scope
      `totalSurfaceArea` to active faces before `:530-531`; bypass `:540-687` in favour of
      one `ReferenceSurface` + `isotropicRemesh(work, ..., iso.region = &region)` +
      `quad->quadrangulate(work, ...)`; skip `:690-715`, `:719-722` and `:723-816`;
      `result.mesh = std::move(work)`.
- [ ] 4.3 Fill `solvedFaces` = live minus frozen, `interfaceVertices` = pinned with an
      active incident face.

## 5. Engine: fatal parameter issues (loud refusal, not silent override)

- [ ] 5.1 `remesh_params.cpp validate()` — with a region present, emit a FATAL
      `ParameterIssue` for each of `pureQuads == true`, `holeFillMaxBoundary >= 3`,
      `smallPatchPolicy != KeepAll`.
- [ ] 5.2 Verify `pipeline.cpp:502-509` turns each into `RunStatus::Error`.
- [ ] 5.3 Extend `tests/core/test_remesh_params.cpp` with the three cases.

## 6. Engine: field-aligned quadrangulator additions

- [ ] 6.1 `field_quadrangulator.hpp` — third factory overload taking `const RegionSolve*`.
      Ids are stable in this path (no `extractIsland`, no `fromIndexed`), so unlike patch
      0003's guides the mask can be constructor-injected BY ID.
- [ ] 6.2 `projectGuides` (`:521-553`) — skip any candidate face with ≥ 2 pinned vertices,
      so a guide stroke cannot overwrite the interface's Dirichlet pin. Do NOT touch
      `crossfield.cpp/.hpp` (patch 0003 owns them; the pins are already hard at `:186-189`).
- [ ] 6.3 New `pairInterfaceRingFirst(mesh, field, region)` between `:471` and `:479`, per
      design Stage 5, reusing the `quadQuality` × field-diagonalness weight (`:169-180`)
      and ascending-`EdgeId` ordering for determinism.

## 7. Engine: verifyInterfaceConformance — exactness gate + irregularity report

**Revised after the spike.** Two tiers, and the split is the point: refuse on anything that
breaks EXACT LANDING (proven achievable), report anything about IRREGULARITY (measured
unachievable by any local pass). Refusing on irregularity rejected every fixture.

- [ ] 7.1 New `core/interface_conformance.{hpp,cpp}`.
- [ ] 7.2 REFUSE tier — `RunStatus::Error`, no ghost, offending ids in `interfaceIssues`:
      a prescribed vertex dead or moved (bitwise), a lost interface edge, a frozen face ring
      changed. These are exactly the properties the spike measured as always-holding, so a
      failure here is a real regression, not a hard problem.
- [ ] 7.3 REPORT tier — never blocks publication: per-vertex `incidentSolvedFaces(b)` vs
      `q_in(b)` with the differing ids listed, the index-identity residual
      `Σ_interior(4-deg) + Σ_boundary(3-deg) − 4χ`, and the count of triangles incident to an
      interface edge. Callers decide what to do with a non-zero count.
- [ ] 7.4 Call it from the pipeline region branch after quadrangulation, before `std::move(work)`.

## 8. Engine C API

- [ ] 8.1 `cyber_mesh_set_solve_region(CyberMesh*, const uint32_t*, size_t)` following the
      `cyber_retopo_patch_clone` id-array contract (`:699` — alive ids, no repeats,
      `CYBER_ERR_INVALID_ARG`, mesh untouched on failure).
- [ ] 8.2 `cyber_mesh_solved_faces`, `cyber_mesh_interface_vertices`, and
      `struct CyberRegionSolveReport { uint32 interface_vertex_count; int32
      interior_index_budget; uint32 residual_triangles; uint32 unresolved_count; }`.
- [ ] 8.3 `cyber_mesh_vertex_face_count` — the valence primitive, verified absent
      (`cyber_capi.h` mentions "valence" only in prose at `:284`, `:452`, `:542`). The
      entire 5.3 test strategy rests on it.
- [ ] 8.4 `cyber_mesh_duplicate(const CyberMesh*, CyberMesh**)` — id-preserving clone
      (`*out = new CyberMesh{in->mesh}` plus the handle side-channels at `:93`, `:99-100`).
      Today the only cross-ABI copy is a `payloadData` OBJ round-trip, which renumbers and
      would void every id-based assertion.
- [ ] 8.5 `cyber_remesh` (`:261`): when `solveRegionFaces` is non-empty, force
      `CYBER_QUAD_FIELD_ALIGNED` (mirroring the guide force at `:307-309`), build the
      `RegionSolve`, pass it down, copy the report onto the out handle.

## 9. Engine tests (ship inside patch 0006)

- [x] 9.1 New `tests/core/test_region_solve.cpp`: Invariant P (every pinned `VertexId`
      alive at a bitwise-identical `Vec3` after a full region solve); Invariant F (every
      frozen `FaceId` alive with an identical `faceVertices` ring); the interface `EdgeId`
      set unchanged **at 4× density** — the test that actually pins the SplitPass guard, since
      a low-density run passes with or without it.
- [ ] 9.2 The index identity holds on every fixture. NOT DONE — `interiorIndexBudget` is
      computed and reported but nothing asserts it yet; it needs the task-7 report tier to be
      meaningful.
- [x] 9.3 The region walk returns the correct ring where `boundaryChain` returns empty
      (see 2.2 — same test).
- [x] 9.4 Added to `tests/CMakeLists.txt`. NOTE: `scripts/build_engine.sh:198-199`
      sets `CYBER_BUILD_TESTS=OFF`, so these need a separate host configure with
      `-DCYBER_BUILD_TESTS=ON` — document the command in design.md. Without this, patch
      0006 ships with the same zero-engine-test posture patch 0003 did.

## 10. Patch 0006 — PARTIAL (tasks 1-3 only; extend as 4-9 land)

- [x] 10.1 Confirmed the submodule worktree equals HEAD + 0001..0005 before starting
      — verified `+1087 -169` across 13 files, matching the patch stack's own numstat sum
      exactly, so the tree held no stray edits before authoring.
- [x] 10.2 Authored `Engine/patches/0006-cybertopology-regional-prescribed-boundary-solve.patch`
      (tasks 1-3: +845 across 7 files). Verified it touches NO file owned by 0001-0005, so a
      plain `git diff HEAD` over its own files is exactly its delta.
- [ ] 10.2b Extend 0006 as tasks 4-9 land. ORIGINAL NOTE retained:
      against the FULLY PATCHED tree. 0002/0003/0004 own `capi.cpp`/`cyber_capi.h`; 0003 owns
      `field_quadrangulator.{cpp,hpp}`. `pipeline.{cpp,hpp}`, `isotropic.{cpp,hpp}`,
      `remesh_params.{hpp,cpp}`, `boundary.hpp` and the new files are owned by no existing patch.
- [x] 10.3 Verified from a PRISTINE tree (stashed to bare HEAD, replayed 0001→0006): all six
      apply cleanly, the engine rebuilds, and the reconstructed tree passes the full suite —
      **274 test cases, 126 112 assertions, 0 failures**, no golden regenerated. That green run
      over the pre-existing goldens is also task 16.1's null-object evidence at the ENGINE
      layer (the CyberKit half of 16.1 still stands).
- [x] 10.4 0006 paragraph added to the `scripts/build_engine.sh` header block, in numbered
      order after 0005, with the `TODO(upstream)` note in the house style.

## 11. CyberKit: primitives

- [ ] 11.1 `MeshAnnotations.swift` — `setSolveRegion(faces:)`, `solvedFaceIDs()`,
      `interfaceVertexIDs()`, `vertexFaceCount(_:)`, `regionBoundaryLoops(faces:)`, each a
      two-call size-then-fill in the shape of `liveFaceIDs()` (`:286`) / `faceVertices(_:)` (`:298`).
- [ ] 11.2 `Mesh.swift` — `duplicated()` over `cyber_mesh_duplicate`, and
      `remeshedRegion(faces:parameters:onProgress:isCancelled:)` mirroring the existing
      `remeshed(...)` progress/cancel plumbing.

## 12. CyberKit: the region backend as a second conformance

- [ ] 12.1 `public struct RegionWeaveSolver: WeaveSolving` per design Stage 0, plus a
      dispatching `CompositeWeaveSolver` routing `.wholeMesh` → `EngineRemeshSolver` and
      `.faces` → `RegionWeaveSolver`. **Do NOT delete the guard at `WeaveSolver.swift:171`** —
      the protocol doc at `:133-142` already promises exactly this swap, and keeping it makes a
      whole-mesh regression structurally impossible.
- [ ] 12.2 Extend `SolverGhost` (`:126-133`) additively with `interfaceVertices: [UInt32]`,
      `interiorIndexBudget: Int`, `residualTriangles: Int`, all defaulted.
- [ ] 12.3 Implement the `frozenFaces` subtraction (where `WeaveConstraints.frozenFaces` stops
      being stored-and-never-read) and the prescribed-spacing `targetQuads` derivation —
      `targetQuads ≈ regionArea / meanPrescribedBoundaryEdgeLength²`. Without it the region
      inherits the whole-mesh default of 50 000 (`remesh_params.hpp:14`) and density fights the
      pinned interface. This is also most of 5.5a's implicit sizing.
- [ ] 12.4 Document in the `SolveRegion` doc comment that `.faces(everyLiveFace)` is NOT
      equivalent to `.wholeMesh` (the region path skips weld/orient/islands/pureQuads and
      preserves ids). Aliasing them silently would be a lie.

## 13. App wiring

- [ ] 13.1 `AutoRetopoSession.swift` — add `region:` (default `.wholeMesh`) to
      `beginAutoRetopo`, thread through `solveOffMain` (`:89-108`).
- [ ] 13.2 Leave `acceptAutoRetopo` (`:108-121`) unchanged, but comment that a region accept
      still replaces the whole EditMesh and therefore invalidates every face id and any
      face-keyed annotation — the same as a whole-mesh accept, but far more surprising for an
      edit the user perceives as local.
- [ ] 13.3 Surface `residualTriangles` and a rejected-solve message in the Auto-Retopo banner
      rather than swallowing them.

## 14. Tests: the 5.3 proof (CyberKit, simulator + device)

All assertions run against the LIVE ghost handle, never through `payloadData()` —
`io_obj.cpp:156` writes at default ostream precision (6 significant digits) and
`MeshPayload.swift:47` documents that ids are not preserved, so a payload round-trip
provably cannot distinguish "never touched the vertex" from "snapped to within 1e-6".

- [ ] 14.1 `regionSolveLandsOnPrescribedVerticesExactly` — every interface vertex alive with a
      `Float.bitPattern`-identical position. No tolerance.
- [ ] 14.2 `regionSolveLeavesFrozenTopologyIdentical` — for every frozen `FaceId` f,
      `ghost.faceVertices(f) == source.faceVertices(f)` (same id, ring, order). The strongest
      single assertion available; subsumes positional comparison.
- [ ] 14.3 `regionSolvePreservesInterfaceEdgeSet` at 4× density — derive the interface
      vertex-pair set from the frozen rings in both meshes and assert Set equality. Catches the
      SplitPass hazard that 14.1 and 14.2 both miss.
- [ ] 14.4 `regionSolveReportsInterfaceIrregularity` — the REPORT is correct, not that it is
      zero: on a fixture with known irregular interface vertices the reported ids match the ones
      an independent `vertexFaceCount` sweep finds, and the index-identity residual matches an
      independently computed value. Asserted on the output quad mesh, NOT on
      `SeamlessSetup::singularityIndex` (vacuously 0 on boundaries,
      `seamless_solver.cpp:136-139`). A caller-supplied valence override at a vertex removes it
      from the report. **Deliberately NOT asserting zero irregularity — see 5.3a.**
- [ ] 14.5 **Negative control:** the identical region through `EngineRemeshSolver` must FAIL
      14.1 and 14.2. Without it these can pass vacuously.
- [ ] 14.6 Rejection cases, each asserting its own distinct reason: odd-parity loop,
      non-conforming interface valence, surviving interface triangle, non-disk region,
      disconnected face set, dead/empty/whole-mesh face set, coincident-duplicate source.

## 15. Tests: goldens and determinism

- [ ] 15.1 New float-free `*.interface.golden` format — integers only: interface `VertexId`s
      canonically rotated to start at the minimum id, per-vertex charges, the index budget, each
      solved quad as four ids rotated to its own minimum, sorted interior valences, boundary
      valences in ring order. Byte-reproducible across platforms and accel backends. The existing
      `*.payload.golden` corpus provably cannot carry this proof (see 14 preamble).
- [ ] 15.2 Fixtures: `region_solve_grid66_center`; `region_solve_lshape` (contains a reflex ring
      vertex, so it proves the accounting is not just "a rectangle"); `region_solve_sphere_cap`
      (same ring combinatorics as the flat case on a curved surface — must produce an IDENTICAL
      `.interface.golden`, proving the guarantee is topological); `region_solve_pentagon` (nonzero
      budget: at least one interior irregular vertex MUST exist).
- [ ] 15.3 Keep a companion `.payload.golden` per fixture in
      `CyberKit/Tests/CyberKitTests/Goldens/MeshEdits/` as a separate, clearly-labelled test, so an
      interior numerical wobble never masquerades as an interface-guarantee failure.
- [ ] 15.4 Determinism: solve twice, and solve with a SHUFFLED region face-id array; both
      byte-identical (mirrors `guidedSolveIsDeterministic`, `WeaveSolverTests.swift:319-330`).
- [ ] 15.5 Invert `WeaveSolverTests.swift:332` into a narrowed
      `@Test("EngineRemeshSolver still rejects a sub-region")` so the backend split is itself pinned.

## 16. Null-object regression

- [ ] 16.1 Every existing `WeaveSolverTests` and MeshEdits golden passes BYTE-IDENTICALLY, with no
      golden regenerated. Guaranteed by `RegionSolve::empty()` short-circuiting and by `region = {}`
      being defaulted; this is the test that keeps patch 0006 from silently regressing shipped
      Auto-Retopo.
- [ ] 16.2 Explicit test asserting an empty region set produces a byte-identical solve, mirroring
      task 5.2 of add-weave-guide-field-steering.

## 17. Validation

- [ ] 17.1 `openspec validate add-weave-regional-solve --strict`.
- [ ] 17.2 Full CyberKit suite green on simulator AND device; engine + CyberKit link.
- [ ] 17.3 Engine C++ suite green under a host configure with `-DCYBER_BUILD_TESTS=ON`.
- [ ] 17.4 Update `openspec/changes/add-cybertopology-app/tasks.md`: mark 5.1a's region-scoped
      clause done; mark 5.3 done ONLY for exact boundary landing, stating in the entry that the
      interior-only-singularity half is measured-and-reported, not guaranteed; add `5.3a` for that
      half in the house "split out honestly" style, citing the b-matching characterisation. Also
      note in 5.7 that the interface-singularity marketing claim is unsupported until 5.3a lands.
- [ ] 17.5 Update `scripts/build_engine.sh` docs and the repo README's engine-patch table.

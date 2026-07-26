# Tasks: add-weave-regional-solve

Ordered. **Task 0 is a falsification spike and gates everything after task 3** — do not
author patch 0006 until its number (c) is measured on three fixtures.

## 0. Falsification spike — RUN 2026-07-26. **THE FALSIFIER FIRED. STOP.**

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

- [ ] 0.4 **DECISION REQUIRED before tasks 1-17.** Per design risk 1, "C's lattice becomes
      the right answer and this decision should be revisited rather than defended."
      Options: (i) re-spine on the boundary-staircase lattice (construct-correct, narrower
      — B = 0 only); (ii) keep this spine but make the interface fan a CONSTRAINT of the
      isotropic stage rather than something checked afterwards; (iii) relax 5.3 to
      positional landing only, dropping the interior-singularity guarantee and with it the
      differentiator. **Tasks 1-3 below are validated by the spike and survive any of the
      three; tasks 4-17 are on hold.**

## 1. Engine: RegionSolve core (new files, zero patch conflict)

- [ ] 1.1 `src/core/include/cyber/core/region_solve.hpp` — `struct RegionSolve` with
      `frozenFace`, `vertexPinned`, `interfaceLoops`, `targetValence`, `indexBudget`,
      `empty()`, `active(FaceId)`, `pinned(VertexId)`. Document Invariants F and P
      inline, citing `mesh.cpp:44-46`/`86-90` and `isotropic.cpp:31-38`.
- [ ] 1.2 `src/core/src/region_solve.cpp` — `buildRegionSolve()` per design Stage 2
      (a)-(g), in that exact order; `tagFeatureEdges` BEFORE `setFeatureEdge`
      (`mesh_diagnostics.cpp:182-203` overwrites every alive edge's flag).
- [ ] 1.3 Add both to `src/core/CMakeLists.txt`.

## 2. Engine: region-scoped boundary walk (header-only, read-only)

- [ ] 2.1 In `retopo/boundary.hpp`, add `isRegionBoundaryEdge(mesh, e, mask)` (exactly
      one incident face in the region) and `regionBoundaryLoops(mesh, mask)`,
      parameterising `detail::nextBoundaryEdge` (`:35`) on the predicate and reusing the
      bidirectional walk, `closed` flag, pinch stop (`:44-46`) and deterministic
      prefix-prepend (`:107`) verbatim.
- [ ] 2.2 Unit-test that this returns the correct 16-vertex ring on an interior 4×4 block
      where the existing `boundaryChain` (`:63`) returns empty.

## 3. Engine: the SplitPass guard

- [ ] 3.1 `isotropic.hpp` — add `const RegionSolve* region = nullptr;` to
      `IsotropicOptions`, and extend the feature-preservation paragraph at `:16-18`
      (which promises collapse/smooth/flip protection but is silent on splits).
- [ ] 3.2 `isotropic.cpp` — immediately after `const auto [a, b] = m_mesh.edgeVertices(e);`
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

## 7. Engine: verifyInterfaceConformance — the gate

- [ ] 7.1 New `core/interface_conformance.{hpp,cpp}`.
- [ ] 7.2 The three checks from design Stage 6: per-vertex `incidentSolvedFaces(b) ==
      q_in(b)`; the index identity `Σ_interior(4-deg) + Σ_boundary(3-deg) == 4χ`; no
      triangle incident to an interface edge.
- [ ] 7.3 On any failure return `RunStatus::Error` with the offending source vertex ids in
      `interfaceIssues`; publish nothing.
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

- [ ] 9.1 New `tests/core/test_region_solve.cpp`: Invariant P (every pinned `VertexId`
      alive at a bitwise-identical `Vec3` after a full region solve); Invariant F (every
      frozen `FaceId` alive with an identical `faceVertices` ring); the interface `EdgeId`
      set unchanged **at 4× density** — the test that actually pins the SplitPass guard, since
      a low-density run passes with or without it.
- [ ] 9.2 The index identity holds on every fixture.
- [ ] 9.3 `regionBoundaryLoops` returns the correct ring where `boundaryChain` returns empty.
- [ ] 9.4 Add the file to `tests/CMakeLists.txt`. NOTE: `scripts/build_engine.sh:198-199`
      sets `CYBER_BUILD_TESTS=OFF`, so these need a separate host configure with
      `-DCYBER_BUILD_TESTS=ON` — document the command in design.md. Without this, patch
      0006 ships with the same zero-engine-test posture patch 0003 did.

## 10. Patch 0006

- [ ] 10.1 Confirm the submodule worktree equals HEAD + 0001..0005 before starting
      (`git -C Engine/CyberRemesherAndUV status` currently shows it dirty).
- [ ] 10.2 Author `Engine/patches/0006-cybertopology-regional-prescribed-boundary-solve.patch`
      against the FULLY PATCHED tree. 0002/0003/0004 own `capi.cpp`/`cyber_capi.h`; 0003 owns
      `field_quadrangulator.{cpp,hpp}`. `pipeline.{cpp,hpp}`, `isotropic.{cpp,hpp}`,
      `remesh_params.{hpp,cpp}`, `boundary.hpp` and the new files are owned by no existing patch.
- [ ] 10.3 Verify the full stack 0001→0006 applies cleanly and the engine rebuilds (limited
      parallelism, no OOM), matching the 0003 task 3.3 precedent.
- [ ] 10.4 Add the 0006 paragraph to the `scripts/build_engine.sh` header block (lines 20-52)
      with a `TODO(upstream)` note in the house style.

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
- [ ] 14.4 `regionSolveKeepsSingularitiesOffTheInterface` — every interface vertex's
      `vertexFaceCount` equals its target; the index identity holds; irregular interior vertices
      are reported and their ids absent from `interfaceVertices`. Asserted on the output quad
      mesh, NOT on `SeamlessSetup::singularityIndex` (vacuously 0 on boundaries,
      `seamless_solver.cpp:136-139`).
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
      budget: at least one interior irregular vertex MUST exist and none may be on the interface).
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
      clause done, mark 5.3 done with the enforce-or-fail scope stated explicitly, and add a `5.3a`
      for the deferred remainder (construct-correct / prescribed interior cone placement) in the
      house "split out honestly" style.
- [ ] 17.5 Update `scripts/build_engine.sh` docs and the repo README's engine-patch table.

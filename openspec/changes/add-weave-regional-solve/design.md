# Design: add-weave-regional-solve

Regional prescribed-boundary Weave solve (tasks 5.1a + 5.3). This document records
the approach, the evidence behind it, and — deliberately — where the three
independent design reviews disagreed, so a later reader can tell a decision from a
default.

Every file:line citation below was verified against the engine tree at
`Engine/CyberRemesherAndUV` (v0.2.4 + patches 0001-0005).

## Spine choice, and where the judges disagreed

The three judges split cleanly and the split is informative rather than noise.

- **Correctness** ranked C (Boundary-Staircase Lattice) 9, A (Carve-Pin-Weld) 7, B (Frozen-Complement) 5.
- **Feasibility** ranked B 8, C 7, A 5.
- **Incrementality** ranked B 9, A 7, C 5.

**The real disagreement is C vs B, and it is about what "guarantee" means.** C makes both 5.3 properties *theorems*: exact landing because the prescribed VertexId is an argument to `Mesh::addFace` and never a value that gets read or written, and interior-only singularities because a simple polyomino's interior lattice points all have four cells. Both of C's identities were re-derived and both hold. But C's shipped slice only handles interior index budget B = 0, which means it emits **zero singularities anywhere** and rejects everything else — including, by C's own weakness 2, the common case where a perfectly ordinary quad patch fails *translation closure*. The correctness judge scored the theory; the other two scored what actually ships.

**B has the strongest exactness mechanism of the three and, as written, no guarantee at all on the property that is the differentiator.** The correctness judge's counterexample is concrete and stands: B pins interface *positions* and interface *edges*, but nothing controls how many solved faces end up incident to an interface vertex. The incident-solved-face count at P is (interior spokes at P) + 1; FlipPass guards only feature EDGES, so flipping an interior spoke into or out of P is legal, and SplitPass's `pinned(a) && pinned(b)` guard does not apply to a spoke with one pinned endpoint. On B's own 6x6 fixture a mid-side interface vertex can end with 3 solved quads instead of 2 — total valence 5, a new singularity ON the interface, shipped silently. B's justification ("Poincare-Hopf does the rest") conflates the total index with per-vertex regularity.

**Resolution: take B's spine and import C's accounting as a gate.** B's failure is not that its mechanism is wrong, it is that it has no oracle. C supplies an exact, O(V), solver-free oracle. Grafting it converts B's silent failure into A's enforce-or-fail, which the correctness judge explicitly credits A for ("the GATE still holds... which is why A still scores well"). The result keeps B's small diff, its patch-stack safety and its null-object regression proof, while closing the one hole that cost it the correctness lens.

**A is not the spine, for a verified reason.** A's central claim — "The ONLY renumbering is stage-3's toIndexed/fromIndexed (pipeline.cpp:700-715)" — is false. `extractIsland(work, islandFaces[i])` runs at pipeline.cpp:605, inside the run, and routes through `Mesh::fromIndexed` (pipeline.cpp:56). A's `PipelineResult::vertexRemap` therefore maps island-local ids to output ids, not carve-local to output, and A explicitly forbids a positional fallback. The failure is silent past `Mesh::validate()`. A's carve insight is genuinely elegant, and its refusal discipline is grafted below, but its identity chain needs three compositions rather than one and it did not budget for that. A's over-valence repair is also mis-specified: collapsing an interior edge (P, X) in a quad mesh turns each incident quad into a triangle, it does not merge two quads.

**One more disagreement worth recording, because it contradicts the brief.** The task framing asks to "extend patch 0003's CrossFieldConstraint mechanism from soft seeds to hard constraints". Verified at crossfield.cpp:186-189: `if (constrained[c]) { continue; }` — pinned faces are never written back, so their seeded cos/sin(4a) survives every sweep byte-exact while still acting as a source column for neighbours. That is an exact Dirichlet condition, with no weight, no stiffness and no partial pin. **The pins are already hard.** The real defect patch 0003 left is PRECEDENCE: the external-constraint loop (crossfield.cpp:102-119) runs after the feature/boundary loop, never checks `constrained[c]`, and by design lets "the user's intent win" — so a guide stroke landing on an interface face erases the interface prescription. Precedence is fixed by filtering `projectGuides` (field_quadrangulator.cpp:521-553) rather than by touching crossfield.cpp/.hpp, which patch 0003 owns; this avoids enlarging 0006's conflict surface for no behavioural gain.

---

## Mechanism, stage by stage

### Stage 0 — Swift: validate and scope (RegionWeaveSolver)

Reject empty, duplicated or dead face ids against `source.liveFaceIDs()` (MeshAnnotations.swift:286). Compute `regionIDs = Set(ids).subtracting(constraints.frozenFaces)` — this is where `WeaveConstraints.frozenFaces` (WeaveSolver.swift:53) stops being stored-and-never-read. Reject if the remainder is empty or equals every live face.

Derive density from the *prescription*, not from a global preset (graft from A): `targetQuads ~= regionArea / meanPrescribedBoundaryEdgeLength^2`, computed from `faceVertices` (MeshAnnotations.swift:298) and `vertexPosition`. Without this the region inherits the whole-mesh `targetQuadCount` (default 50,000, remesh_params.hpp:14) and the density constraint fights the pinned interface — a conflict nothing in the pipeline detects. This is also most of task 5.5a's implicit sizing.

Then `try source.setSolveRegion(faces: regionIDs.sorted())` before the remesh, exactly parallel to the existing `setOrientationGuides` call at WeaveSolver.swift:186.

### Stage 1 — capi: side-channel, then refuse incompatible parameters loudly

`struct CyberMesh` (capi.cpp:90-102) gains `std::vector<uint32_t> solveRegionFaces`, set by `cyber_mesh_set_solve_region`. This is the patch-0003 precedent verbatim (guidePoints/guideDirs at :99-100), so `cyber_remesh`'s signature is untouched.

When the set is non-empty, `cyber_remesh` (capi.cpp:261) forces `quadMethod = CYBER_QUAD_FIELD_ALIGNED`, mirroring the guide force at :307-309.

**Graft from A:** the *other* incompatible parameters become FATAL `ParameterIssue`s emitted from `remesh_params.cpp validate()`, not silent overrides in capi. `pureQuads == true`, `holeFillMaxBoundary >= 3`, and `smallPatchPolicy != KeepAll` are each fatal when a region is present. pipeline.cpp:502-509 already converts a fatal issue into `RunStatus::Error`, so this is a structured, unit-testable refusal, and it protects a direct C++ caller of `cyber::remesh::remesh` who would otherwise reach `linearSubdivide` at :787 and the unguarded reprojection at :803-809.

### Stage 2 — buildRegionSolve: masks, prescription, budget, preconditions

Order matters and is load-bearing.

**(a) Validate and refuse hostile inputs (graft from A).** `weldCoincidentVertices` (pipeline.cpp:67-119) is skipped in region mode because it round-trips through `fromIndexed` and would renumber. Rather than skip it silently, detect coincident duplicates up front and hard-error ("region contains coincident duplicate vertices; weld the document first"). Note the function returns the input bit-identically when nothing is coincident (:98-100), so this failure is input-conditional and clean-grid goldens would never have caught the corrupt version. Same for inconsistent winding, since `orientFacesConsistently` (:130-220) is likewise skipped.

**(b) Region topology preconditions (graft from C).** Require the region to be face-connected; compute chi = V - E + F over region-incident elements; require exactly one interface loop for the strong guarantee, and accept multiple loops with the interior-index claim degraded to per-loop parity (stated honestly in the spec). Each rejection has its own distinct reason code, not a generic error.

**(c) frozenFace mask.** `frozen[f] = 1` for every live face NOT in the region. **Invariant F:** frozen faces are never removed by any pass, so their ids never enter `m_freeFaces` (mesh.cpp:86-90) and can never be recycled (mesh.cpp:44-46). `active(f) := isAlive(f) && !frozen[f]` therefore stays correct for the entire run even while region face ids churn freely.

**(d) Region-scoped triangulation.** For each active face with `faceSize > 3`, call `Mesh::triangulateFace(f)` (mesh.hpp:87, impl mesh_ops.cpp:353-364). It only calls `splitFace`; it never touches `m_vertices`. The frozen complement keeps its quads and n-gons. The whole-mesh `work.triangulate()` at pipeline.cpp:527 is skipped.

**(e) Feature tagging, in this order.** `work.tagFeatureEdges(params.sharpEdgeDegrees)` FIRST — verified at mesh_diagnostics.cpp:182-203, it rewrites `feature` on every alive edge, so running it after would erase our tags. Then `setFeatureEdge(e, true)` (mesh.hpp:160) on every edge incident to a frozen face. That covers both the interface edges (one active + one frozen face, so `edgeFaceCount == 2` and `isBoundaryEdge` is FALSE — which is exactly why `boundaryChain` cannot see them) and every interior edge of the complement.

**(f) vertexPinned mask.** Set for every vertex incident to at least one frozen face. An O(F) sweep; no ordered walk needed. **Invariant P:** a pinned vertex has at least one feature edge, hence `isFeatureVertex` is true for it (isotropic.cpp:31-38 — "any incident feature edge"), hence it is never collapsed, never dissolved, never rotation-eligible, never smoothed. It is therefore never freed, so its id is never recycled and the mask stays valid for the whole solve.

**(g) Interface loops, prescription and budget (graft from C, feeding the gate).** Walk the interface into ordered loops with the new region-scoped `boundary.hpp` predicate. For each interface vertex b: `q_out(b)` = live incident faces NOT in the region (`Mesh::vertexFaces`, mesh.hpp:145); target total valence `T(b)` = 4 for a vertex interior to the host mesh, 2 for one on the host rim, **overridable per vertex by the caller** (graft from both A's and C's flagged gap — an artist-placed pole on the interface is legitimate and must not force a rejection). Required in-region quad count `q_in(b) = T(b) - q_out(b)`; boundary charge `c_b = 2 - q_in(b)`; interior index budget `B = 4*chi - sum(c_b)`.

Reject up front on odd loop length (an odd-edge disk boundary admits no all-quad fill, period) and report B.

### Stage 3 — density and reference surface

`totalSurfaceArea` summed over ACTIVE faces only, so `targetEdgeLength(activeArea, effectiveQuads, edgeScale)` is region-scoped. One `ReferenceSurface reference(work, params.smoothNormalDegrees)` built ONCE before mutation.

### Stage 4 — isotropic, in place

`IsotropicOptions` gains `const RegionSolve* region = nullptr`. Only `SplitPass::run` changes — the four-line guard described above. Every other pass is already stopped by Invariant P.

### Stage 5 — quadrangulate, in place, field-aligned only

Ids are stable in this path (no extractIsland, no fromIndexed), so unlike patch 0003's guides the mask can be constructor-injected BY ID: a third `makeFieldAlignedQuadrangulator(iters, guides, const RegionSolve*)` overload. Two additions inside `quadrangulate` (field_quadrangulator.cpp:462), both no-ops when `m_region == nullptr`:

1. `projectGuides` (:521-553) skips any candidate face with >= 2 pinned vertices — the precedence fix.
2. `pairInterfaceRingFirst(mesh, field, region)` between `computeCrossField` (:471) and `collectPairEdges` (:479): for each interface edge in ascending EdgeId order, take its active-side triangle and merge it with the better-scoring of its two non-interface edges, scored with the existing `quadQuality` * field-diagonalness weight (:169-180), tie-broken on lower EdgeId. This closes the interface ring into quads before the global matching can strand it.

Nothing else in the path needs changing: `collectPairEdges` (:156), `mopUpTriangles` (:442) and `quadValenceCleanup` (:566) all already `continue` on `isFeatureEdge`, so every frozen face and every interface edge is inert.

### Stage 6 — verifyInterfaceConformance: the gate

**This is the graft that turns 5.3 from "likely" into "guaranteed or refused".** After quadrangulation, before publication:

1. **Per-vertex interface regularity.** For every interface vertex b: `incidentSolvedFaces(b) == q_in(b)`, equivalently total valence `== T(b)`. This is the check whose absence lets B ship a valence-5 interface vertex.
2. **The index identity.** Over the solved patch, `sum_interior(4 - deg) + sum_boundary(3 - deg) == 4 * chi`. Re-derived: for a quad disk, `4F = 2*E_int + E_bnd` and `E_bnd = V_bnd`, so the expression is `4*V_int + 2*V_bnd - 4F`, and Euler gives `F = V_int + V_bnd/2 - 1`, leaving exactly 4. O(V), no solver state, and it is the *only* non-vacuous oracle available — `SeamlessSetup::vertexIndex` returns 0 for every boundary vertex by construction (seamless_solver.cpp:136-139), so any assertion built on it passes trivially.
3. **No triangle touches the interface.** `pairInterfaceRingFirst` still respects the verified hard geometric veto at `quality <= 0.2f` (field_quadrangulator.cpp:171), so a badly-shaped interface triangle can survive. That is a failure, not a footnote.

Any failure returns `RunStatus::Error` with the offending source vertex ids in the report. No ghost is emitted. Some regions therefore produce nothing — that is the honest trade, and it is stated in the spec rather than buried.

### Stage 7 — publish

`result.mesh = std::move(work)`. No island merge, no `fromIndexed`, no `fillHoles`, no `applySmallPatchPolicy`, no pureQuads block. `solvedFaces` = live minus frozen (valid by Invariant F); `interfaceVertices` = pinned vertices with at least one active incident face.

`RegionSolve::empty()` short-circuits every branch above, and `region = {}` is a defaulted trailing parameter on `remesh()`, so `.wholeMesh` executes today's code byte-for-byte. **Whole-mesh regression safety is a property of the code, not of an audit** — which is precisely what A's design could not claim (its own weakness 11 concedes the point).

---

## The two guarantees, stated precisely

### G1 — Exact boundary landing (5.3 property 1). IDENTITY, not a snap, not a tolerance.

For every prescribed interface vertex v:
- v is alive in the output with the SAME VertexId, and `position(v)` is **bitwise identical** to the input (compare `Float.bitPattern` per component, never `abs(a-b) < eps` — a tolerance turns "landed exactly" into "landed nearby", which is the failure this change exists to eliminate);
- and, the stronger form: for every frozen FaceId f, `faceVertices(f)` is IDENTICAL to the input — same face id, same ring, same order.

Mechanism, as a chain of verified facts:
1. `Mesh work = input` is a value copy of the id arrays; the three rebuilds that destroy ids (pipeline.cpp:527-529) and the two that renumber later (extractIsland at :605, the stage-3 merge at :715) are all skipped.
2. `Mesh::triangulateFace` only calls `splitFace` (mesh_ops.cpp:353-364) — never touches `m_vertices`.
3. Pinned vertices are never MOVED: `SmoothAndProjectPass` skips feature vertices (isotropic.cpp:318) and every pinned vertex is a feature vertex by Invariant P; `relaxQuadMesh` is not called (its only call sites, pipeline.cpp:779 and :810, are inside the skipped pureQuads block); the unguarded whole-vertex reprojection at :803-809 is unreachable.
4. Pinned vertices are never REMOVED or REPLACED: CollapsePass (:209-212), removeDoublets (field_quadrangulator.cpp:91-99, the only vertex deleter in this path), eligibleVertex (:274-286). `mergePair` and `applyRotation` re-add faces over the same existing VertexIds.
5. The prescribed EDGE SET also survives — the SplitPass guard. This is the property a positional test would miss entirely.

### G2 — All singularities interior (5.3 property 2). GATED, not constructed.

Every interface vertex ends with total valence exactly `T(v)`, its prescription derived from the frozen side (or a caller override). Because the total index is fixed by the surface's topology, forcing every interface vertex regular pushes the residual index strictly interior. The output reports `interiorIndexBudget`, and the index identity is asserted at runtime.

The strength, stated honestly: **this is enforce-or-fail, not construct-correct.** A ghost that violates it cannot exist, at the cost that some regions produce no ghost. The construct-correct alternative is C's lattice, which is strictly narrower (B = 0 only, plus translation closure, plus injectivity, plus disk-only, plus no density control) and is the right follow-on if the gate's rejection rate turns out to be high — see the spike in risks.

---

# ADDENDUM — spike result, 2026-07-26

The falsification spike (tasks.md task 0) ran. **G1 holds; G2 does not, and the proposed
remedy for G2 does not move the number.** Full data in tasks.md §0; the argument is here.

## What survived

The exactness mechanism is confirmed by measurement, not by audit:

- Prescribed positions were bitwise identical in every configuration, including with the
  SplitPass guard disabled — Invariant P (a pinned vertex is a feature vertex, hence never
  collapsed / smoothed / dissolved) does the work claimed of it.
- The SplitPass guard is load-bearing and cheaply justified: without it, 4× density
  corrupted **20 frozen face rings and lost 16 interface edges**; with it, zero and zero.
  This also confirms the "positional assertion passes while vertex identity fails" hazard
  is real — the unguarded run kept every prescribed POSITION while destroying the
  prescribed EDGE SET, exactly as predicted.

Tasks 1, 2 and 3 are therefore validated as written, whatever spine is chosen next.

## What failed, and why it is structural

Every prescribed-density failure was `expected 2 → actual 3`: one extra solved quad at a
mid-side interface vertex, total valence 5, a singularity ON the interface.

`pairInterfaceRingFirst` was then implemented and measured. It performed 11-16 merges per
fixture and changed the failure count by **zero**.

The reason it cannot help:

> The number of solved quads incident to an interface vertex `b` is determined by the size
> of the triangle fan the ISOTROPIC stage leaves around `b`. Pairing merges triangles into
> quads; merging two triangles that both touch `b` reduces `b`'s incident count by one, but
> the pairing pass chooses merges by local quad quality and has no term for `b`'s target
> count. Changing which triangles pair redistributes quality, not valence.

So the design's error is one level up from the pairing: it treats the interface fan as
something to *verify after the fact* when it is something that must be *constrained during
generation*. The gate then converts a generation problem into a refusal.

## Where that leaves the three designs

The correctness judge ranked this spine last (5/10) on precisely this point and supplied
precisely this counterexample. The spike confirms the judge and disconfirms the synthesis's
resolution ("B's spine plus C's identity as a hard gate"), because the gate can only refuse
what the spine keeps producing.

Three ways forward, in the order they should be considered:

1. **Constrain the fan during the isotropic stage** (new option, cheapest if it works):
   give `SplitPass`/`CollapsePass` a per-pinned-vertex target fan size and let the existing
   passes converge to it, the way they already converge edge length to a target. This keeps
   the whole B spine — masks, feature tagging, in-place ids, null-object safety — and moves
   the guarantee from enforce-or-fail to converge-or-fail. Unvalidated; would need its own
   spike, and the spike harness now exists.
2. **Re-spine on the boundary-staircase lattice** (design C): construct-correct, and its
   two identities were re-derived and hold. Strictly narrower — interior index budget B = 0
   only, plus translation closure, plus injectivity, plus disk-only, plus no density
   control — so it ships a guarantee over a smaller domain.
3. **Relax 5.3 to positional landing only.** G1 is proven and cheap; drop the
   interior-singularity clause. This closes 5.1a and part of 5.3 quickly, but it gives up
   the property that distinguishes Weave from "run Quadriflow on a sub-mesh and stitch",
   so it should not be chosen silently.

Option 3 would require rewriting the spec delta's "Singularities are interior to the solved
region" requirement, not merely deferring it.

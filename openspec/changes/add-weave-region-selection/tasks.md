# Tasks: add-weave-region-selection

Selection, domain construction, session and presentation over the API
`add-weave-regional-solve` already shipped. **No engine change** — every primitive
this needs already ships (`cyber_mesh_boundary_loop`,
`cyber_retopo_extend_boundary_grid` with a Target snapper, `cyber_mesh_set_solve_region`).
If a task here turns out to need one, it is out of scope and belongs in 5.4b.

## 0. Feasibility spike — RUN 2026-07-26. **GROWING WORKS. The falsifier did not fire.**

- [x] 0.1 `WeaveFillSpikeTests`: a 4x2 quad cage covering the lower band of a domed
      24x24 triangle Target; walk its free edge; `extendBoundary` 2 rows with the
      Target snapper; region-solve exactly those 8 seed faces with the cage frozen.
- [x] 0.2 Measured, after the density fix below:

      (a) cage vertices moved 0/15, cage face rings changed 0/8
      (b) orphaned interface vertices 0 — manifold across the seam
      (c) irregular interface vertices 0/5, seam triangles 1
      (d) seed deviation from Target 7.5e-09; SOLVED deviation 0.0126 = 0.031 quads

- [x] 0.3 **(d) does not fire.** The solved band sits 3% of a quad off the Target, so
      building the `ReferenceSurface` from cage+seed rather than from the Target is a
      quality detail, not a blocker. **5.4b stays a follow-up** — and that downgrade is
      now measured rather than assumed, which was the point of asking.
- [x] 0.4 **The spike found a real bug, and it was load-bearing.** `validate()` floored
      `targetQuadCount` at 100 — a whole-mesh assumption. The prescribed budget for the
      seed band was 7 quads, silently clamped to 100, and the solve produced **77 faces,
      11x too fine**, with **4 of 5 interface vertices irregular**. That floor defeated
      `prescribedQuadBudget` outright, i.e. the spec's "auto-filled regions match manual
      scale with no dials". Fixed in patch 0006: the floor is 4 when a region is present,
      100 otherwise. After the fix the same solve produces 5 faces and **0/5 irregular**.
      A 6x-too-dense patch welded onto a coarse cage is wrong output however clean its
      seam, so this is the right trade — but it is a trade: the coarser solve leaves
      residual SEAM TRIANGLES the quadrangulator cannot pair (4 on the 6x6 proof
      fixture, 1 here). They are reported via `interfaceTriangles`; reducing them belongs
      with 5.3a. The `add-weave-regional-solve` interface goldens were regenerated —
      they had been recorded at the clamped density.

## 1. Domain construction (CyberKit) — DONE

- [x] 1.1 `WeaveFillDomain.grow(cage:snapper:towards:rows:maximumRows:)`. Signature
      differs from the plan: it takes `towards` — where the user asked to fill — and it
      is REQUIRED, for a reason the plan missed. **Any cage patch's boundary is a CLOSED
      loop**, and `extendBoundary` steps the whole chain by ONE translation, so handing
      it the closed ring would SHIFT the cage rather than extend it. `facingRun` selects
      the contiguous stretch of the ring lying on the fill side of its centroid, which
      is what makes a single translation the correct operation. Without a fill direction
      there is no non-arbitrary run, hence `Failure.noFillDirection`. Refusals are
      typed and distinct: `noOpenBoundary`, `noFillDirection`, `runTooShort`,
      `degenerateStep`.
- [x] 1.2 `WeaveFillDomain.rows(toCover:from:of:step:maximumRows:)` — rows to reach the
      furthest painted point along the step direction, capped (the runaway-rows hazard
      task 4.2 already had to bound). Paint BEHIND the boundary asks for one row, not a
      negative count.
- [x] 1.3 The seed is built on `cage.duplicated()` — the ID-PRESERVING clone from task
      8.4, not a payload round-trip, which would renumber the very ids `chain` refers to.
      So the live cage is provably untouched (asserted on face ids AND rings) and a
      discarded proposal leaves nothing behind, without any undo bookkeeping.
- [x] 1.4 Covered by 6 tests: the facing run is the +y edge of a closed rectangular
      loop (not all 14 vertices), the live cage is unchanged, grown vertices lie on the
      Target within 1e-5, a CLOSED cage is refused, row derivation and its cap, and a
      grown domain solving with the prescribed boundary bitwise preserved.

## 2. The armed tool — DONE

- [x] 2.1 `RetopoTool.weaveFill` + `EditorAction.weaveFill`/`.clearWeaveFill`,
      toolbar-assignable, with gallery entries whose help states both gestures and
      records why it is not a lasso. The action count guard in
      `ToolbarConfigurationTests` moved 34 → 36 deliberately: it exists so an action
      added without a gallery entry fails rather than shipping a blank help panel.
- [x] 2.2 `isCameraManipulator = false`; tap vs paint via `CameraToolStrokes.isTap`.
- [x] 2.3 **No new helper needed** — `context.snapper` IS the Target snapper, so the
      existing `strokeSurfaceHits` already returns Target-surface points. The plan
      assumed Patch Clone resolved against the EditMesh and that a Target variant would
      be needed; it does not, and it is not.
- [x] 2.4 Capture resolves a stroke into a `WeaveFillIntent` (fill point, painted
      extent, tap flag) and journals NOTHING. A TAP replaces the request ("fill here",
      not "also here"); a PAINT stroke unions its hits and re-centres the fill point, so
      a second stroke both extends the reach AND steers which stretch of cage boundary
      gets grown. A stroke that missed the Target asks for nothing and must not clear a
      request the user already made.
- [x] 2.5 **The all-tools probe invariant needed an honest exemption.**
      `visualVerificationProbesJournalEveryTool` asserts every tool's probe journals;
      Weave Fill capture deliberately does not, because the document changes only on
      ACCEPT. Exempted alongside Guide, with a note to RE-INCLUDE it once task 3 wires
      accept into the probe — at that point the exemption becomes a hole rather than a
      fact. Recorded rather than silently widened.

## 3. Session and solve — DONE

- [x] 3.1 `beginWeaveFill()` on the Coordinator (not `MeshEditController` — the
      proposal slot and the accept path live on the Coordinator). It **reuses the
      Auto-Retopo proposal slot**, so the amber ghost, the Accept/Discard bar, the
      13.3 notice, one-entry accept and byte-exact undo all come for free, and the
      user can only review one proposal at a time anyway.
- [x] 3.2 **Runs ON the main actor, deliberately — the plan was wrong to say off.**
      `beginAutoRetopoAsync` crosses the actor boundary by serialising meshes to
      payload `Data`, and that payload is OBJ at DEFAULT OSTREAM PRECISION — six
      significant digits — which also renumbers every element. A whole-Target solve
      does not care: nothing of its input survives into the output. **A fill does**:
      the cage is frozen and must come back BITWISE identical, because it is the
      artist's hand-authored geometry. Round-tripping it would quantise every cage
      vertex, silently degrading work done by hand. Affordable because a fill solves
      the coarse CAGE plus a small seed band, never the multi-million-triangle Target
      (only touched through the already-built snapper while growing). If a fill ever
      needs to be async, the fix is a `Sendable` id-preserving transfer, not a payload
      round-trip.
- [x] 3.3 Presents through the existing amber ghost + bar; the 13.3 notice carries the
      region report, and a REFUSAL reuses the same line with its own message per
      `WeaveFillDomain.Failure` case (asserted distinct).
- [x] 3.4 Accept is one journal entry and one undo restores the pre-accept bytes —
      asserted end to end on a domed Target with a partial cage.
- [x] 3.5 **The teardown was a genuine hazard, not a formality.** A fill ghost CONTAINS
      the cage, so a stale one is dangerous rather than merely outdated: accepting it
      after an undo would put the pre-undo cage back. `weaveFillBasePayload` pins the
      cage a proposal was derived from and `discardWeaveFillIfStale` drops the proposal
      AND the captured request on any external snapshot change, hooked next to the
      existing `editMeshSnapshotWillChange`. A whole-Target proposal has no base payload
      and is deliberately unaffected. Both directions asserted (stale drops, unchanged
      keeps).
- [x] 3.6 **Integration miss found by the tests: the app still injected
      `EngineRemeshSolver()`.** Task 12 built `CompositeWeaveSolver` and described it as
      "the solver an app should inject" — and nothing injected it, so every `.faces`
      solve hit the whole-mesh guard and failed. Every fill test failed identically
      until it was wired. Auto-Retopo is unaffected (the composite routes `.wholeMesh`
      to the same backend), which the existing suite confirms.

## 4. Live re-solve

- [ ] 4.1 Re-solve when the extent or density changes; debounce so a multi-stroke
      paint does not launch a solve per stroke.
- [ ] 4.2 **Generation-token the in-flight solve** so a superseded result is dropped,
      not presented — the 3.5 interpretation chip's `generation` token is the precedent.
- [ ] 4.3 Re-solving journals nothing and replaces the pending ghost rather than
      stacking a second one.

## 5. Tests

- [ ] 5.1 Seeding: rows are welded to the cage boundary and lie on the Target; no
      open boundary refuses with its own reason.
- [ ] 5.2 Cage faces and boundary vertices are unchanged across an accepted fill —
      same id, same ring, bitwise identical positions, asserted on the LIVE handle.
- [ ] 5.3 The Target is byte-unchanged by a fill.
- [ ] 5.4 Accept journals exactly once and undoes byte-exactly; discard journals
      nothing AND leaves no seed rows in the document.
- [ ] 5.5 Painting further re-solves and replaces the ghost; document unchanged.
- [ ] 5.6 A superseded in-flight solve never becomes the presented ghost.
- [ ] 5.7 Bare Target disconnected from the cage is refused, not mis-filled.
- [ ] 5.8 A UI test driving the REAL tool: arm, tap, accept, undo.

## 6. Validation

- [ ] 6.1 `openspec validate --changes --strict`.
- [ ] 6.2 Full app-hosted suite green on the simulator; no golden regenerated.
- [ ] 6.3 Update `add-cybertopology-app/tasks.md`: tick 5.4a's region-UX clause with
      the painted/tap correction stated; add **5.4b** (external reference surface);
      record on **5.6** what tap-to-fill already delivers and what remains (deciding
      whether to solve speculatively on hover).

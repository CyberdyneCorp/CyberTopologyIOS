# Tasks: add-interface-singularity-guarantee

> **OUTCOME: REFUTED at task 0.4. Tasks 1-5 are NOT started.**
> Locking interface-adjacent edges forces `k(b) = 0` exactly as predicted — and that makes
> conformance strictly WORSE on every fixture at every density (`lshape` 0 -> 12 irregular,
> `grid66_center` 3 -> 14, `sphere_cap` 0 -> 14; best case 16 -> 16), because `q_in(b)`
> counts the quads the cage expects while `k(b) = 0` guarantees triangles. Seam quality
> collapses too: `lshape` and `cross` lose every quad in the solved region. Numbers,
> reasoning and a reproducible harness: `spike/RESULTS.md`, `spike/interface_lock_spike.cpp`.
> This is the FOURTH refuted attempt at 5.3a. The fallbacks are deliberately not started.

**Spike-gated, and the spike can refute the whole approach.** Three earlier attempts at
this failed by trying to control `k(b)` (merges at an interface vertex); this one controls
`n(b)` (the fan) and forces `k(b) = 0`. Do not build the gate promotion (task 3) before
task 0 says the residual is small enough for refusal to be usable.

## 0. Spike: does forcing k(b)=0 plus fan normalisation actually converge?

- [x] 0.1 On a throwaway branch, after the isotropic stage in the region branch, mark every
      edge INCIDENT to an interface vertex as a feature edge. `collectPairEdges` already
      skips feature edges, so this alone should drive `k(b)` to zero — verify that directly
      by measuring `faces(b) − n(b)` per interface vertex, which must be 0 for every one.
- [x] 0.2 Report the fan error `n(b) − q_in(b)` per interface vertex on all four fixtures
      (grid66_center, lshape, cross, sphere_cap) at prescribed density. **This is the number
      the whole approach rests on**: with `k(b) = 0`, conformance IS `n(b) = q_in(b)`.
- [x] 0.3 **NOT BUILT — 0.1/0.2 made it moot.** With `k(b) = 0` the fan must collapse from
      the isotropic stage's 5-6 triangles to a prescription of 2-3 at EVERY interface vertex
      simultaneously. That is a large topological change, not a local flip, so the pass this
      task describes could not close the gap even if written.
- [x] 0.4 Re-measure conformance. **Falsifier:** if the residual on `lshape` is not
      materially better than the current 5-of-16, the local hypothesis is wrong and this
      change stops — the fallbacks are the boundary-staircase lattice (construct-correct,
      narrower) or a real b-matching solver, and neither should be started speculatively.
- [x] 0.5 Also measure what locking costs: interface-adjacent edges can no longer be
      merged, so triangles may survive at the seam (`interfaceTriangles`) and interior quad
      quality near the boundary may drop. A guarantee bought with a visibly worse seam is
      not obviously a good trade, so report both before committing to it.

## 1. Engine (patch 0008), only if task 0 converges

- [ ] 1.1 Interface-adjacent feature locking in the region branch, after isotropic and
      before quadrangulation. Must be scoped to the region: locking must not leak into a
      whole-mesh solve, which the null-object test will catch.
- [ ] 1.2 Fan-normalisation pass with the deterministic ordering from 0.3, bounded by a
      pass cap so an unsatisfiable fan cannot loop.
- [ ] 1.3 Engine tests: fans hit their target on the four fixtures; the pass is
      deterministic; a whole-mesh solve is byte-identical (the null-object property).

## 2. Report the true residual

- [ ] 2.1 `interfaceIrregular` must stay accurate — a guarantee that is enforced by
      refusing still needs the report, because a caller has to tell "clean" from "declined".
- [ ] 2.2 Keep the caller's valence override honoured: an authored pole is measured against
      the override, not the cage.

## 3. Promote the gate (the actual guarantee)

- [ ] 3.1 `verifyInterfaceConformance` moves interface irregularity from its REPORT tier to
      its REFUSE tier. **Only once 0.4 shows the residual is small** — refusing on a common
      case would ship a solver that will not solve, which is exactly what the original
      enforce-or-fail design did and why it was rescoped.
- [ ] 3.2 The refusal names the offending vertices and publishes nothing.
- [ ] 3.3 Spec delta's requirement flips from "measured and reported" to the guarantee.

## 4. Tests

- [ ] 4.1 Every fixture that publishes a ghost has ZERO irregular interface vertices —
      replacing today's "the report is correct" assertion with the guarantee itself.
- [ ] 4.2 **Delete the L-shape counterweight test** (`reflexRingStillIrregular`), which
      currently asserts the guarantee does NOT hold. It exists so the gap cannot be closed
      by accident; closing it deliberately means removing it, and leaving it would be the
      clearest possible sign the work is not actually done.
- [ ] 4.3 An unachievable region refuses and names vertices, with the mesh unchanged.
- [ ] 4.4 Whole-mesh solves byte-identical; no golden regenerated except the interface
      goldens this deliberately changes.

## 5. Validation and claims

- [ ] 5.1 `openspec validate --changes --strict`; full suite on simulator AND device;
      engine suite via `build_engine.sh --host-tests`.
- [ ] 5.2 Update master 5.3a → done, and 5.3's entry to state the guarantee now holds in
      full rather than for exact landing only.
- [ ] 5.3 **Unblock the claim in 5.7**: the note forbidding "Weave places no singularity on
      a prescribed interface" comes off ONLY when 3.1 is enforcing and 4.1 asserts it.
      Table 2 of the benchmark (where rivals are undefined rather than worse) becomes
      publishable at that point and not before.

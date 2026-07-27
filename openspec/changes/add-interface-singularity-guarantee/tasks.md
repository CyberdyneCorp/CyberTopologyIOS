# Tasks: add-interface-singularity-guarantee

**Spike-gated, and the spike can refute the whole approach.** Three earlier attempts at
this failed by trying to control `k(b)` (merges at an interface vertex); this one controls
`n(b)` (the fan) and forces `k(b) = 0`. Do not build the gate promotion (task 3) before
task 0 says the residual is small enough for refusal to be usable.

## 0. Spike: does forcing k(b)=0 plus fan normalisation actually converge?

- [ ] 0.1 On a throwaway branch, after the isotropic stage in the region branch, mark every
      edge INCIDENT to an interface vertex as a feature edge. `collectPairEdges` already
      skips feature edges, so this alone should drive `k(b)` to zero — verify that directly
      by measuring `faces(b) − n(b)` per interface vertex, which must be 0 for every one.
- [ ] 0.2 Report the fan error `n(b) − q_in(b)` per interface vertex on all four fixtures
      (grid66_center, lshape, cross, sphere_cap) at prescribed density. **This is the number
      the whole approach rests on**: with `k(b) = 0`, conformance IS `n(b) = q_in(b)`.
- [ ] 0.3 Add a fan-normalisation pass: while `n(b) ≠ q_in(b)`, flip a `(b, interior)` edge
      to move the fan by one, preferring flips that do not disturb another interface vertex.
      Deterministic ordering (ascending vertex id, then ascending edge id).
- [ ] 0.4 Re-measure conformance. **Falsifier:** if the residual on `lshape` is not
      materially better than the current 5-of-16, the local hypothesis is wrong and this
      change stops — the fallbacks are the boundary-staircase lattice (construct-correct,
      narrower) or a real b-matching solver, and neither should be started speculatively.
- [ ] 0.5 Also measure what locking costs: interface-adjacent edges can no longer be
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

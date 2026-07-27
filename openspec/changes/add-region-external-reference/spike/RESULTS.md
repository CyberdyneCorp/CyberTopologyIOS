# Task 0 results — PROCEED, and caching is mandatory rather than optional

Both spikes link the built host-test libs (`Engine/build/engine-host-tests`) rather than
adding cases to the engine submodule, which enforces a patch-stack discipline.

## 0.1 / 0.2 — the defect is real, and 0.031 quads did NOT generalise

Interior-vertex deviation from the true Target, in QUAD edge lengths (the unit 5.4b's
recorded 0.031 figure used), at 4x density on a 6x6 cage over a 9216-face Target:

| Target | reference used | mean | max |
|---|---|---|---|
| smooth dome | working mesh (**today**) | 0.1451 q | 0.3506 q |
| smooth dome | the Target | 0.0000 q | 0.0000 q |
| **rippled** | working mesh (**today**) | **0.4187 q** | **1.2567 q** |
| **rippled** | the Target | 0.0000 q | 0.0000 q |

**The recorded 0.031 quads does not hold even on smooth geometry** — this measures 0.145
mean / 0.351 max there, roughly 5-10x the filed figure. On geometry with detail finer than
the seed band it is 0.419 mean and **1.257 max**: the worst interior vertex sits more than a
full quad edge away from the surface it is supposed to lie on. That is not a subtle quality
item.

The max-versus-mean split is the signature task 0.2 was written to look for: on the rippled
Target the max is 3x the mean, which is what localised lost detail looks like. A mean-only
measurement would have understated this by a factor of three.

**Read the Target-reference column as a control, not as a result.** Deviation is measured
against the same `ReferenceSurface` that variant (b) projects onto, so 0.0000 is tautological
— it confirms the harness is wired correctly, nothing more. The number that matters is the
working-mesh row: how far today's output actually sits from the Target.

## 0.3 — the cost is real: caching is required, not a nice-to-have

`ReferenceSurface` construction is linear in face count, ~636 µs per 1k faces:

```
    9216 faces      4.9 ms
   65536 faces     36.3 ms
  262144 faces    157.6 ms
  640000 faces    418.8 ms
 1210000 faces    769.5 ms
```

Extrapolating to the 4.8M-triangle real Target: **~3.0 seconds**.

That settles the open design question in the proposal. A fill currently runs
**synchronously on the main actor** — a deliberate choice, documented in
`WeaveFillSession`, because the payload round-trip would quantise hand-authored cage
geometry. Paying 3 seconds of BVH build there would freeze the UI on every fill. So caching
keyed on the reference handle moves from "obvious mitigation, not worth designing yet" to a
requirement of this change (task 2.3 is no longer conditional).

## 0.4 — decision: PROCEED

The gate was written to allow closing 5.4b as measured-and-not-worth-it. It does not close:
the deviation is an order of magnitude larger than filed and visible on detailed geometry,
which is precisely the case a Weave Fill over a real scan hits.

Two things change in the plan as a result:

- Task 2.3's caching is mandatory, not conditional on 0.3.
- Task 4.1's threshold comes from these numbers rather than a guess: today's output must
  improve materially against the 0.419 mean / 1.257 max baseline on rippled geometry.

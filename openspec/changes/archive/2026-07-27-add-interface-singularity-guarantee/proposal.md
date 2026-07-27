# Proposal: add-interface-singularity-guarantee

## Why

Weave's headline claim (`docs/COMPETITOR_IDEAS.md` §2.2) is that a solved region meets
hand-authored topology on a prescribed boundary with **no singularity on the interface** —
*"what 'run Quadriflow on a sub-mesh and stitch' cannot do."*

Half of that shipped. `add-weave-regional-solve` proved EXACT LANDING: interface vertices
keep their ids and bitwise positions, the interface edge set survives, frozen faces keep
their rings, and the solve refuses rather than publish a violation.

The other half did not. Interface regularity is **measured and reported, never
guaranteed**. On the committed fixtures at prescribed density, `grid66_center` and
`sphere_cap` come out clean; **`lshape` shows 5 of 16 interface vertices irregular.** So
the claim is true sometimes, and the product currently tells the user a count instead of
keeping a promise. Task 5.7's competitive table — where rivals score *undefined* rather
than worse — is gated on this, and the roadmap already forbids publishing the claim until
it lands.

## What we know, from three refuted attempts

The face count at interface vertex `b` after quadrangulation is

    faces(b) = n(b) − k(b)

where `n(b)` is the triangle fan the isotropic stage leaves at `b`, and `k(b)` is the
number of merges the quadrangulator makes **across edges incident to `b`**. Conformance
needs `faces(b) = q_in(b)`, the count the frozen cage prescribes.

All three previous attempts tried to control **k(b)**, and all three failed (measured, in
`add-weave-regional-solve` design.md ADDENDUM 1-2):

- greedy interface-first pairing — changed the failure count by **exactly zero**, because
  pairing decides *which* triangles merge, not how many quads meet a vertex;
- degree-constrained pairing — **deadlocked**, leaving 3 of 16 unresolved, because a merge
  across `(b,x)` decrements BOTH endpoints, so adjacent interface vertices compete;
- degree pairing plus a post-hoc fan lock — no better, and it made `sphere_cap` worse by
  removing an accidental repair.

The conclusion drawn at the time was that this is a coupled degree-constrained
(b-)matching over the interface ring, needing a global combinatorial solver.

## The hypothesis this change tests instead

**Control `n(b)` and force `k(b)` to zero.** Then the coupling disappears.

1. **Force `k(b) = 0`** by marking every edge INCIDENT to an interface vertex as a feature
   edge before quadrangulation. `collectPairEdges` already skips feature edges, so no
   merge can cross them — this is the same mechanism that already protects the interface
   itself, so it is proven machinery rather than new risk.
2. Conformance then reduces to **`n(b) = q_in(b)`**, which is a purely LOCAL per-vertex
   property. With `k(b)` identically zero there is nothing to trade between neighbours,
   so the deadlock that killed attempt 2 cannot arise.
3. **Normalise the fan** to hit it: an edge flip on a `(b, interior)` edge changes `n(b)`
   by one and is local. This is the classic valence-optimisation move, applied to a
   prescribed target rather than to "toward six".

Each of those `n(b)` triangles then becomes a quad by merging across its edge OPPOSITE
`b` — which is not incident to `b`, so it is not locked. A triangle that fails to pair
stays a triangle at the seam: a quality issue counted by `interfaceTriangles`, not an
irregularity.

**This may still fail**, and the change is structured to find that out cheaply. Fan
normalisation is not always topologically achievable, so the gate stays enforce-or-report
either way — the question is whether the residual is rare enough to call the guarantee
real.

## What Changes

- **Engine (patch 0008):** interface-adjacent feature locking, and a fan-normalisation
  pass targeting `q_in(b)` by local flips, both inside the region branch.
- **The conformance gate is promoted** from reporting irregularity to REFUSING it, once
  the spike shows the residual is small enough that refusal does not reject ordinary work.
- **Spec:** the "Interface irregularity is measured and reported" requirement becomes a
  guarantee, with the refusal contract stated.

## Non-Goals

- **Prescribed interior cone placement** — the caller still cannot say "put a pole here".
- **The boundary-staircase lattice** (design C of the original analysis). It remains the
  fallback if this hypothesis fails: construct-correct but strictly narrower.
- **A general b-matching solver.** If the hypothesis fails, that is the next thing to
  scope, not something to build speculatively now.

## Notes

The measured mitigation already in place matters to the sizing: deriving density from the
prescribed boundary spacing (`RegionWeaveSolver.prescribedQuadBudget`) made the flat and
domed fixtures clean. So this change is about the reflex-ring case and its relatives — a
narrower target than the original 3-of-16-everywhere picture, which is why a local
mechanism is worth trying before a global solver.

# Implicit sizing from a prescribed interface (5.5a)

## Why

5.5 shipped GLOBAL density (coarse/medium/fine presets). 5.5a is the other half: a region
solve should size itself from the boundary it must land on, so an auto-filled patch matches
the surrounding cage with no density dial — the spec's "auto-filled regions match manual
scale with no dials".

**It already works, and that is the finding rather than the excuse.** 5.5a was recorded as
"doubly blocked" on regional solve and the frozen-patch model. Both have since landed, and a
spike measured what actually happens rather than assuming work remained:

| region | derived budget |
|---|---|
| whole 6x6 unit grid, 36 faces | 36 |
| centre 4x4 block, 16 faces | 16 |
| same block with the inner 2x2 FROZEN, 12 faces solved | 12 |
| same 16-face block at HALF the spacing | 16 |
| one square face whose boundary is subdivided into 8 half-edges | **4** (face count is 1) |

Three properties fall out, and only the last two are load-bearing:

1. A frozen patch shrinks the budget, because `RegionWeaveSolver` subtracts frozen faces
   BEFORE deriving, so the frozen patch's own boundary joins the interface it measures.
2. **Scale invariance** — the same cage at half spacing asks for the same number of quads.
   This is what "no dials" means: the budget tracks the cage's proportions, not the
   document's units. A budget that grew when the model was scaled down would need a dial to
   correct it.
3. **It follows interface SPACING, not face count.** On a uniform grid `area / spacing²`
   equals the face count, so no grid fixture can tell those apart. The octagon can: one
   face, boundary subdivided, budget 4. Without that case every assertion here would pass
   against an implementation that merely counted faces.

## What changes

**No behaviour change.** This change adds the spec requirement and the tests that pin the
three properties down.

That is worth doing precisely BECAUSE nobody implemented it deliberately. It emerged from
`add-weave-constraint-authoring` subtracting frozen faces, meeting a derivation
(`prescribedQuadBudget`) written for the fill path. Nothing currently states it must hold,
so a refactor could replace the derivation with a face count and the entire existing suite
would stay green. An accidental property with no test is a property that leaves silently.

Also pinned: the solve must USE the derived budget over the caller's preset. That failure
already shipped once in reverse — a region inheriting the whole-mesh 50 000-quad default
fought the pinned interface and welded a wildly over-fine patch onto a coarse cage — so the
override is asserted rather than trusted.

## Non-goals

- **A density BRUSH.** Spatially varying density within one region is 5.2b
  (`add-weave-density-radial-symmetry`), and needs `DensityField` to gain a per-vertex
  channel.
- **Changing the derivation.** Area over mean-interface-spacing-squared is what the measured
  properties describe; this change locks it, it does not tune it.
- **Surfacing the number in the UI.** `prescribedQuadBudget` is already public so a caller
  can show the density a region WOULD get, but no screen asks for it yet, and adding one
  without a place to put it would be speculative.

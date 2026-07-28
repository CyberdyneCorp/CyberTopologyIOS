# Auto-seam proposals that respect manual seams (6.5)

## Why

6.2 made seams authorable, which means an artist can now do all of the work by hand. 6.1's
one-tap unwrap is the other extreme: it chooses every seam itself. Neither is the point of
this product — the Weave pattern is that the artist places the few cuts that matter and the
solver fills in the rest, landing exactly on what they authored.

6.5 is that pattern for seams: propose the remaining cuts, as a GHOST the artist accepts or
discards, without touching what they already drew.

## What "respecting manual seams" has to mean

Two readings, and only one is useful:

- **Preserve them in the output.** Necessary but weak: a proposal that keeps the artist's
  seams while ignoring them during chart growth can suggest a cut two edges away from one
  they already made.
- **Treat them as barriers during growth**, so the proposal answers "given your cuts, where
  else would I cut". That is what makes it assistive rather than a second opinion.

This change does both. `computeCharts` grows a chart across edges; a manual seam becomes an
edge it will not cross. The proposal is then unioned with the manual set, which guarantees
preservation even though the later chart-merge passes are not barrier-aware — so an accepted
proposal can never delete a seam the artist drew.

**Known limitation, stated rather than discovered:** `mergeCoplanarCharts` and
`mergeByDistortion` can still merge two charts that a manual seam separates. The union
re-cuts along that seam, so the RESULT is correct, but the auto seams around it may be placed
as if the manual cut were not there. Making the merge passes barrier-aware is a further
change and is not pretended to be done here.

## Reuses, not reinvents

The accept/discard shape already exists from Phase 5 — a proposal held until the artist
commits it, journaling nothing on discard and one entry on accept. A seam proposal is much
simpler than a mesh ghost (an edge set, not geometry), so it reuses the SHAPE without
needing `SolverGhost`.

## Non-goals

- **Proposing seam REMOVAL.** A proposal only ever adds. Suggesting the artist's own cuts be
  undone is a different and much more presumptuous feature.
- **Live re-proposal as seams are drawn.** That means running chart growth per stroke; the
  proposal is explicit, on request, like Auto-Retopo.

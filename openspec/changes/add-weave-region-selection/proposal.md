# Proposal: add-weave-region-selection

> **Revised.** The first draft framed a region as "a patch of existing EditMesh faces
> to re-weave". That is a real operation but it is the SECONDARY one, and it is not
> what Weave is for. Corrected below; the painted-selection decision survives, the
> rest is rewritten.

## Why

`add-weave-regional-solve` shipped regional prescribed-boundary solve end to end and
proved exact landing. **It has no user** — nothing in the app produces a region, so
`region:` is only ever `.wholeMesh` and the whole feature is dormant.

What Weave is for (`docs/COMPETITOR_IDEAS.md` §2): the artist hand-draws the ~10% of
topology that needs judgment; the solver fills the boring ~90% **between and around
it**, landing exactly on the hand-drawn patch boundaries. The Target is high-poly
triangles and is never modified — it is only the surface everything snaps to. The
EditMesh is the quad cage being authored.

So the operation is: **grow new quads over BARE TARGET, meeting the existing cage's
open boundary exactly.** Not re-weaving faces that already exist.

## What Changes

Two ways in, because they suit different moments and the machinery is shared:

- **Tap to fill** — tap near an open cage boundary and the solver proposes the next
  patch outward from it. No selection UI at all. This is also, verbatim, the spec's
  ambient assist (task 5.6): *"when an EditMesh boundary is open, show the solver's
  proposed next patch as ghost geometry."*
- **Paint to bound** — paint over the bare Target to say how far to fill. The fill
  grows from the cage boundary until it covers the painted extent.

Both produce a ghost through the existing amber Accept/Discard bar, with the region
notice from task 13.3 already surfacing irregular interface vertices.

## Impact

- Affected specs: `weave-solver` (ADDED: fill grows from an open cage boundary over
  bare Target; two entry gestures; extent bounding; live re-solve; selection is not
  journaled).
- Affected code: `RetopoTool.weaveFill` + `EditorAction`; a `WeaveFillSession` on
  `MeshEditController`; domain construction in CyberKit over the EXISTING
  `extendBoundary` facade; `AutoRetopoSession` gains the fill entry point; banner
  copy; `ActionCatalog` entry.
- **No engine change.** Verified: every primitive this needs already ships.
- Affected tests: seeding, both entry modes, re-solve, accept/undo byte-exactness,
  and the refusals.

## Design Decision 1 — the solve domain is grown, not carved

The region solver rewrites faces in place and freezes the complement. Bare Target
has no EditMesh faces on it, so there is nothing to rewrite — the domain has to be
built first. Two ways to build it:

- **Carve** the Target: cut it along the cage's boundary polyline, extract the
  triangles on the fill side, weld. Needs a curved surface cut, which is explicitly
  a 4.1a remainder (the shipped knife is straight-only), plus a weld between cage
  vertices and Target triangle interiors. Substantial new geometry work.
- **Grow** from the boundary: `cyber_retopo_extend_boundary_grid` already appends
  quad rows off an ordered boundary chain, **welded to that chain by construction**
  and **snapped to the Target** (it takes a `CyberSnapper*`). Zero new engine ops.

Growing wins outright. The seed rows do not need to be good — they only need to be a
topologically correct, roughly-placed cover. The region solve then rewrites exactly
those faces into clean quads with the cage frozen, so the interface lands exactly on
the cage's boundary vertices and the density comes from that boundary's spacing via
`prescribedQuadBudget`.

Both entry gestures reduce to the same thing: **how many rows to grow before
solving.** Tap uses a default band; paint grows until the painted extent is covered.

## Design Decision 2 — painted, never lassoed

Unchanged from the first draft, and the reason survives the rewrite.
`simplify-gesture-grammar` cut the lasso from the Pencil grammar on measured device
evidence: a closed quad stroke with a slight overshoot classified as `lasso` →
`hideRegion`. The retired `ActionCatalog` entry records that the capability "returns
as an armed tool".

Paint is a stroke on an ARMED tool, so no shape classification is involved and there
is nothing to misread. 5.4a's "lasso-region" wording should be read as "a way to
bound a region", and 5.4a is updated to say so.

## Design Decision 3 — the reference surface, downgraded

The first draft called this fatal. It is not, because
`cyber_retopo_extend_boundary_grid` snaps the seed rows to the Target, so the
`ReferenceSurface` the region solve builds from cage+seed already approximates the
Target at roughly the seed's density.

It is still worth fixing: the solve refines the seed and reprojects onto that
approximation rather than onto the Target itself, so fine Target detail inside a
coarse seed band is lost. Referencing the Target directly needs the region path to
accept an external reference surface — an engine change. Stays split out as
**5.4b**, now a quality improvement rather than a blocker.

## Non-Goals (deferred)

- **Filling bare Target NOT adjacent to an open cage boundary.** Growing needs
  something to grow from. An island of bare surface away from the cage must be
  REFUSED with a clear reason, not silently mis-filled. Carving (DD1) is what would
  lift this.
- **Filling with no EditMesh at all** — that is whole-mesh Auto-Retopo, already
  shipped.
- Frozen-patch authoring (5.2a's app half): the cage is frozen implicitly by being
  the cage; there is no separate "freeze this" state.
- In-viewport accept/discard gesture shortcuts, and a progress percentage — both
  already deferred in 5.4a.

## Notes

Task 5.6 (ambient assist) is substantially delivered by tap-to-fill: the same
proposal, shown on boundary hover instead of on tap. Whether to auto-show it is a
separate call — it means solving speculatively — so 5.6 stays open and this change
records what it inherits.

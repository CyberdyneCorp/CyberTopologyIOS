# Run the whole-cage commands on the piece you selected, when it is a piece

## Why

Reported from device: two patches in the cage, one selected, Halve declined — *"you can see
one is selected, the other is not, so it should work only on the selected one"*. Deleting the
other patch made it work.

Reported again, for Subdivide: a 30-face patch selected beside another patch, Subdivide, and
BOTH grew — *"the batch operation should work only on the selected faces"*.

Halve is whole-cage because an edge loop does not stop at a patch boundary: dissolving one
partway leaves a hanging half-loop. Subdivide is whole-cage because subdividing a patch splits
the edges it SHARES with its neighbours, leaving them n-gons. Both reasons are sound, and they
are why this was ruled out once already. Neither applies to an ISLAND: nothing outside it is
attached, so no loop can leave it and there is no shared edge to split. Halving or subdividing
an island is exactly as well-defined as doing it to a cage that contained only that island —
which is what deleting the other patch proved by hand.

## What Changes

- **Halve, Subdivide and Subdivide + Reproject scope to the selection when it is a
  self-contained island**, and run whole-cage otherwise, as before.
- **The panel badge follows the SELECTION, not just the command**: "whole cage" appears on
  those three only when the current selection would not scope them.
- **The fallback says which happened**, and why.

Non-goals: an attached selection still does not scope — the hanging half-loop objection stands
there, and nothing here weakens it.

## Design decisions

**Composed, not taught.** Neither operation is made subset-aware. The island is carved onto a
COPY, operated on there as an ordinary whole cage, and spliced back — ONE `withIsland` helper
that both go through. So every rule Halve enforces — all-quad, one rectangle, even spans —
applies to the island unchanged and refuses for its own reasons, with no second implementation
to keep in agreement.

**Ordered so a refusal cannot half-apply.** Everything that can throw happens on the copy; the
real cage is not touched until the halved island exists.

**An island is judged by VERTICES, not edges.** Two patches meeting at a single corner share no
edge, so an edge-based test would call one an island — and the splice would then duplicate that
corner and tear them apart, a defect that would not surface until someone dragged the seam.

## Capabilities

### New Capabilities

- `retopology-tools`: the whole-cage commands act on a selected island.

## Impact

- **Affected specs**: `retopology-tools` (ADDED requirement).
- **Affected code**: new `CyberKit/Sources/CyberKit/MeshHalveIsland.swift` (`withIsland`,
  `halveDensity(limitedTo:)`, `subdivide(limitedTo:reprojectingOnto:)`);
  `MeshEditBatchCommands` (the scope decision and the fallback wording);
  `ViewportInputModel` + `BatchCommandsView` (the badge).
- **Risk**: the splice renumbers ids. The whole-cage halve already does, and the selection is
  dropped on any topology change regardless.

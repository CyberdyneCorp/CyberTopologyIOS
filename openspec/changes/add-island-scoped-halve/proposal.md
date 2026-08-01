# Halve the piece you selected, when it is a piece

## Why

Reported from device: two patches in the cage, one selected, Halve declined — *"you can see
one is selected, the other is not, so it should work only on the selected one"*. Deleting the
other patch made it work.

Halve is whole-cage because an edge loop does not stop at a patch boundary: dissolving one
partway leaves a hanging half-loop. That reasoning is sound, and it is why this was ruled out
once already. But it does not apply to an ISLAND. Nothing outside an island is attached to it,
so no loop can leave it, and halving it is exactly as well-defined as halving a cage that
contained only that island — which is what deleting the other patch proved by hand.

## What Changes

- **Halve scopes to the selection when the selection is a self-contained island**, and runs
  whole-cage otherwise, as before.
- **The panel badge follows the SELECTION, not just the command**: "whole cage" appears on
  Halve only when the current selection would not scope it.
- **The fallback says which happened**, and why.

Non-goals: an attached selection still does not scope — the hanging half-loop objection stands
there, and nothing here weakens it.

## Design decisions

**Composed, not taught.** The halving is not made subset-aware. The island is carved onto a
COPY, halved there as an ordinary whole cage, and spliced back. So every rule Halve enforces —
all-quad, one rectangle, even spans — applies to the island unchanged and refuses for its own
reasons, with no second implementation to keep in agreement.

**Ordered so a refusal cannot half-apply.** Everything that can throw happens on the copy; the
real cage is not touched until the halved island exists.

**An island is judged by VERTICES, not edges.** Two patches meeting at a single corner share no
edge, so an edge-based test would call one an island — and the splice would then duplicate that
corner and tear them apart, a defect that would not surface until someone dragged the seam.

## Capabilities

### New Capabilities

- `retopology-tools`: Halve acts on a selected island.

## Impact

- **Affected specs**: `retopology-tools` (ADDED requirement).
- **Affected code**: new `CyberKit/Sources/CyberKit/MeshHalveIsland.swift`;
  `MeshEditBatchCommands` (the scope decision and the fallback wording);
  `ViewportInputModel` + `BatchCommandsView` (the badge).
- **Risk**: the splice renumbers ids. The whole-cage halve already does, and the selection is
  dropped on any topology change regardless.

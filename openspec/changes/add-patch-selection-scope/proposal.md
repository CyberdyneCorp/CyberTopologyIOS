# Select a patch, then run the batch command on it

## Why

Asked on device: *"When we have the feature to subdivide, halve, etc. (Batch Commands) can
first select the patch of quads that we want this option to be applied? If no patch is
selected then it will be all the patches on EditMesh."* And the gesture: *"today when we hover
a face, if we double click the pen above this face I want to select all the faces on that
patch"* — marked yellowish.

Today every batch command is all-or-nothing. Snapping the whole cage to re-fit one ear also
re-snaps the flank the artist just hand-placed; relaxing to even out a haunch evens out
everything. The commands are useful and blunt.

## What Changes

- **A patch selection on the EditMesh**, drawn in gold, taken by double-tapping the pencil
  over a face.
- **Batch commands run on the selection when there is one, and on the whole cage when there
  is not** — no mode, no extra button.
- **Two commands stay whole-cage and say why** (below).

## Design decision — what "a patch" is

A patch is the GRID BLOCK the tapped face sits in: flood-fill across shared edges, stopping at
separatrices — the edge loops traced from every irregular (non-valence-4) vertex.

That is the retopology notion of a quad patch, and it is the one that matches what the artist
sees: a rectangular region of regular grid, bounded where the topology actually changes. The
alternatives were weighed and rejected: a connected ISLAND is one closed cage after an
auto-retopo, so a tap would select everything and mean nothing; a CREASE ANGLE has nothing to
stop at on an organic model like the bunny, so it bleeds from the ear into the head; and
STOPPING AT AUTHORED MARKS does nothing until marks exist.

A non-quad face has no grid to belong to, so tapping one selects only that face, and a
non-quad is a wall the fill will not cross.

## Design decision — Subdivide and Halve stay whole-cage

Neither can scope to a patch without damaging the cage, so neither pretends to:

- **Subdivide** splits the edges a patch shares with its neighbours. Those neighbours would
  have to absorb the new midpoints (becoming 5-gons) or be fan-triangulated — either way a
  scoped subdivide leaves a border of non-quads in a quad cage, which is exactly what Halve
  and the solver both refuse to work with.
- **Halve** dissolves every other edge loop, and a loop does not stop at a patch boundary.
  Dissolving one partway leaves a hanging half-loop and a stranded mid-vertex.

They run on the whole cage and SAY SO when a selection exists, rather than silently ignoring
it. The commands that scope exactly do scope: Snap All, Relax All, Triangulate, and the four
Clear commands.

## How each scoped command scopes

- **Snap All / Relax All** — by PINNING the complement. The engine already honours a pin set,
  so relaxing the whole cage with everything outside the selection pinned IS relaxing the
  selection, with its border held still. No new engine entry point, and the border behaviour
  is the correct one rather than an approximation.
- **Triangulate** — build the triangles first, then delete the quads they replace: adding
  faces leaves existing ids alone, while deleting compacts them, so the other order would
  invalidate the very ids being worked from.
- **Clear Pins / Loop Tags / Frozen / Seams** — clear only the annotations inside the
  selection.

## Capabilities

### New Capabilities

- `retopology-tools`: a double-tapped quad patch scopes the batch commands.

## Impact

- **Affected specs**: `retopology-tools` (ADDED requirements).
- **Affected code**: new `CyberKit/Sources/CyberKit/QuadPatch.swift` (the patch finder, pure);
  `MeshEditController` (selection state); `MeshEditBatchCommands` (scoping); `HoverPreview`
  (a face-id query); `MetalViewport` + `ViewportRenderer` (the gold fill); `PencilTapAction`.
- **Risk**: face ids do not survive a topology change, so the selection is dropped whenever
  the cage's topology changes — the same rule the painted region follows after a solve.

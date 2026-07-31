# The un-relaxable ear tip

## Why

Reported from device: *"Why I can't Relax this part of the bunny ears?"*

Measured, on a cage from this solver (1108 faces, 1186 vertices):

| relax call, brush centred on the top cage vertex | vertices moved |
| --- | --- |
| the app's brush radius, 130 passes, Target snapping on | **0** of 1186 |
| the same, snapping off | **0** |
| the same, corner auto-pinning off | **0** |
| no brush mask (whole mesh) | 1084 of 1186 |

A vertex deliberately kicked by 5% of the scene radius, sitting AT the brush centre,
recovered 0%. Relax was not weak there; it was inert.

**The cause: 91 of those 1186 vertices belong to no face at all** — 41% of them in the top
15% of the model, the ears, where the cross field is most singular. The engine's Relax builds
a vertex's one-ring from its edges, so a vertex with no faces has nothing to smooth toward
and it `continue`s. Silently. Every one of the 15 vertices under the brush at the ear tip was
one of those.

The reporter's own document corroborates it: **820 v · 742 f**, where a closed quad cage needs
F + 2 = 744. About 76 vertices — the same ~10% — are that litter. A payload round trip
preserves them, so nothing downstream ever cleaned up.

## What Changes

- **A whole-mesh solve drops face-less vertices before shipping the cage.** They are
  un-relaxable, un-editable, and they inflate the vertex count the artist reads.
- **A relax stroke that changed nothing says so**, instead of leaving a tool that looks
  broken.

Non-goals: Relax is not being taught to move such a vertex — there is no meaningful place to
move one to. Nor is it being made non-tangential: it must keep the cage on the Target, so the
tangential constraint stays, which means a vertex whose correction points along its own normal
(every vertex at a tip) still will not move. That is now stated to the artist rather than
hidden.

## Design decisions

**Prune by rebuilding, not by deleting.** The C API prunes isolated vertices only as a side
effect of removing the faces that orphaned them; there is no "drop this vertex" entry point,
so there is nothing to call. `Mesh.append` already copies faces while preserving the source's
vertex sharing exactly, so appending into a fresh mesh keeps every face and only the vertices
those faces use.

**Only the whole-mesh path prunes.** The rebuild RENUMBERS ids, and a prescribed-boundary
region solve reports interface vertices and solved-face ids against its own handle — the same
id-space trap that once made region solves do nothing. A region patch loses its face-less
vertices anyway, on accept, because the merge goes through `append`.

**The notice explains the mechanism, not just the outcome.** "Nothing happened" invites the
artist to try harder in the same place; naming the two immovable cases (no faces, or a tip)
tells them to reach for retopology instead.

## Capabilities

### New Capabilities

- `retopology-tools`: solved cages carry no face-less vertices, and a relax that changes
  nothing reports it.

## Impact

- **Affected specs**: `retopology-tools` (ADDED requirements).
- **Affected code**: new `CyberKit/Sources/CyberKit/MeshPrune.swift`; `WeaveSolver` prunes the
  whole-mesh cage; `MeshEditController.commit` emits the notice.
- **Risk**: the prune rebuilds a cage through `buildFace` on every solve. A failed rebuild
  falls back to the unpruned cage — clutter beats losing the solve.

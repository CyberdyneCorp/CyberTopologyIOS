# Halve the cage's quad density

## Why

Subdivide has no counterpart. `Subdivide` and `Subdivide + Reproject` take a cage from 8x8 to
16x16, but nothing takes it back — a retopology pass that overshoots its density has to be
redrawn or run through the solver. Asked for directly on device: *"a tool that divides or
subdivides a group of quad faces — a 16x16 quads mesh becomes 8x8, or the other way."*

The other way already exists. This change adds the halving.

## What Changes

- **A `Halve` batch command**, beside Subdivide: every other edge loop in each loop family is
  dissolved, so each 2x2 block of quads becomes one quad and 16x16 becomes 8x8.
- **The silhouette is preserved exactly.** The loops that survive include the cage's boundary
  loops, and every vertex that survives keeps its position — nothing is averaged, nothing moves,
  so no Target reprojection is needed or offered.
- **It refuses rather than guesses** on any cage where "every other loop" has no consistent
  answer (see the refusal rules below), leaving the document untouched.

Scope, decided deliberately: **whole cage**, not a selection. An edge loop does not stop at a
selected patch, so a selection-local density change needs transition topology synthesised along
the whole selection border — real work, and the wrong tool for it: `setSolveRegion` +
`setDensityScales` + `remeshedRegion` (the Weave regional solver) already re-meshes an arbitrary
region at a different density and lands exactly on the prescribed boundary.

## How, and what makes it non-obvious

It composes from ops that already exist — `edgeLoop`, `dissolveEdges`, `mergeVertices` — but
NOT in the obvious way, and the spec records this because the obvious way produces invalid
geometry:

Dissolving a loop's edges does **not** leave quads. Two quads sharing a dissolved edge merge
into a SIX-sided face: the two vertices of the dissolved edge survive as valence-2 vertices
sitting mid-side. They have to be removed for the result to be a quad, and each is removed by
merging it into one of its two collinear neighbours (which keeps the neighbour's position, so
the silhouette does not move).

The families are also processed **one at a time** — dissolve family A, clean up to quads, then
family B. Dissolving both first would strand the centre vertex of each 2x2 block inside the
merged face with no edges at all, which no cleanup composed from `mergeVertices` can reach.

Loop ORDER, which "every other" needs, comes from the boundary: walking one side of the patch
visits the perpendicular loops in sequence.

## Refusals

Each leaves the document byte-unchanged and says why:

- **Not quad-only.** A triangle or n-gon has no loop structure to halve.
- **A loop cannot be walked end to end** — it runs into a pole (a vertex of valence != 4), so
  the alternation dead-ends partway across the cage.
- **A family has an odd number of loops.** "Every other" then has no consistent answer; halving
  anyway would leave one row or column double-width, which is a worse outcome than declining.
- **No cage, or a cage of fewer than two loops per family** — nothing to halve.

## Capabilities

### New Capabilities

None — this extends the batch-command roster.

### Modified Capabilities

- `retopology-tools`: the batch-command roster gains Halve, with its refusal rules.

## Impact

- `App/Sources/MeshEditBatchCommands.swift` — the command case, title, notes, and
  `annotationPolicy` (`.rebuilt`: halving destroys the element ids annotations are keyed on,
  exactly as subdivide does).
- `CyberKit/Sources/CyberKit/MeshHalveDensity.swift` (new) — the loop enumeration, the
  alternation, the dissolve + valence-2 cleanup, and the refusals as typed errors.
- Tests: an ops suite (grid halves, silhouette unmoved, each refusal), mirrored into the
  app-hosted target so it runs on device.

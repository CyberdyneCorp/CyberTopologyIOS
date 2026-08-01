# Halve what can be halved

## Why

Reported from device on a clean all-quad patch: **42 v · 30 f**, entirely selected, and Halve
refused with *"Halve needs an even number of quads across, or 'every other loop' has no
answer"*.

Those numbers name the cage exactly. For an m x n grid, `m*n = 30` and `(m+1)(n+1) = 42` give
`m + n = 11`, so the patch is **5 x 6**. Six is even and halves perfectly well; five is odd
and cannot — its last "every other" loop IS the far boundary, so dissolving it would move the
silhouette.

Halve validated BOTH directions before doing anything, so one odd direction refused the whole
operation. The artist was left with nothing on a cage where half the work was available.

## What Changes

- **Each grid direction is judged on its own merits.** The even one is halved; the odd one is
  left alone. Halve refuses only when NEITHER direction can be.
- **The result says which happened**, so a count that did not quarter is explained rather than
  puzzled over.
- **A rectangle check replaces an accidental guard** (below).

## The accidental guard, and its replacement

An L-shaped cage — a grid with an extra quad stuck on one side — used to be refused because
one of its spans happened to be odd. That was luck, not a rule: `requireGridRegular` passes it,
because the extra faces meet at BOUNDARY vertices, which are regular at valence 3.

Judging each direction separately removed the accident and let the L-shape through, which a
regression test caught. So the real invariant is now stated: "every other loop" only has an
answer on a RECTANGLE, and a rectangle is exactly a cage whose two spans multiply to its face
count. That is a better rule than the one it replaces — it refuses for the right reason, and
it says so.

## Capabilities

### Modified Capabilities

- `retopology-tools`: Halve halves the directions that can be halved.

## Impact

- **Affected specs**: `retopology-tools` (MODIFIED requirement).
- **Affected code**: `CyberKit/Sources/CyberKit/MeshHalveDensity.swift`, and the status line
  in `MeshEditBatchCommands`.
- **Risk**: a cage that used to refuse now changes. That is the point, and the silhouette is
  still never moved — the test asserts every surviving vertex was already there.

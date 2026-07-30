# Tasks: improve-vertex-merge

## 1. Merge on both verbs

- [x] 1.1 `commit` merges the seed for Tweak AND Move, journalled `<verb>.mergeSnap`.
- [x] 1.2 Only the seed merges; the falloff is untouched (it never was a merge candidate —
      snap detection only ever tracked `grabbedVertex`).

## 2. The window is the local cell

- [x] 2.1 `mergeRange(around:in:sceneRadius:)` — 45% of the mean length of the edges meeting
      the grabbed vertex, floored at half the old scene-relative window.
- [x] 2.2 Measured ONCE at grab and held on the session: the scan is O(edges) and the range is
      a per-drag constant.

## 3. Name the outcome

- [x] 3.1 `ViewportInputModel.snapHint` — "Merge" while a drag holds a candidate, nil otherwise.
- [x] 3.2 Set from the same viewport callback that drives the highlight.
- [x] 3.3 Shown in the post-stroke chip's slot (a drag and a chip never coexist).

## 4. Tests

- [x] 4.1 `moveDragMergesSeedIntoTheDisconnectedVertexItLandsOn` — the existing Move test,
      rewritten: 16 vertices -> 15, one vertex at the target, verb `move.mergeSnap`.
- [x] 4.2 `mergeRangeFollowsTheLocalCellNotTheScene`: the same cage in a 100-unit and a
      0.001-unit scene yields the SAME cell-derived range; a vertex with no edges falls back to
      the scene window.
- [x] 4.3 Tweak's existing merge test stays green.
- [x] 4.4 Two of my own mistakes, both caught by tests rather than reasoning:
      - the first "floor" was itself scene-relative (`sceneRadius x 0.04 x 0.5`), so on any cage
        smaller than the scene it simply won and reinstated the bug — measured 2.0 against a
        cell of 1. The scene window now applies ONLY when there are no edges to measure.
      - 0.45 of a cell is too eager: it merged a vertex nudged 60% of the way toward its
        neighbour, breaking an existing falloff test. 0.3 means the artist must drag at least
        70% of the way, which is an intent rather than a tweak.

## 5. Close out

- [x] 5.1 `openspec validate --strict`: valid.
- [x] 5.2 Simulator 1091/1091 + 462/462; device (iPad, 4 suites) 79/79.

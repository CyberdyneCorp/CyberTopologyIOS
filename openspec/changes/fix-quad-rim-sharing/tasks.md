# Tasks: fix-quad-rim-sharing

## 1. Recognizer: a rounded bend is one corner (engine)

- [x] 1.1 `tryOpenStrokeCreateFace`: the two-corner branch requires the corners to be separated
      along the stroke (≥ 1/5 of it) AND in space (> 0.25 of the chord). Device stroke 28's
      pair sat at 4/64 and 0.08 of the chord.
- [x] 1.2 Patch-stack entry (0024).
- [x] 1.3 Test `theRecordedDeviceLYieldsAWellProportionedRing`: the RECORDED device stroke,
      decimated and mapped onto the fixture, produces a ring with no collapsed side; the
      existing U test stays green.
- [x] 1.4 HONEST SCOPE: this is hardening, not a proven cause. The offline replay that showed
      one bend counted twice (indices 27/31, 0.08 of the chord) assumed a SQUARE viewport; the
      device runs ~1.33. Replaying the recorded stroke through the real recognizer produces a
      sane ring BEFORE the fix, so the giant quad in the screenshot is explained by the
      single-bend ring being committed as one face — defect 2, which does have a failing-first
      test.

## 2. Created faces share the rim they follow (app)

- [x] 2.1 `rimRun`: the run of consecutive boundary-chain vertices a drawn side FOLLOWS.
- [x] 2.2 `continueAdjacentBoundary` triggers off `rimRun` instead of both corners snapping, so
      an L-derived ring (two corners in mid-air, two existing vertices diagonal) can fire.
- [x] 2.3 The one-cell-append guard survives: a run of 2 vertices (one cell) is not a patch.
- [x] 2.4 Weld each extruded row onto the rim it lands on, so a patch that reaches a second rim
      closes onto it.

Three defects found while making the test pass, each of which had made the feature silently
inert or destructive:

- [x] 2.5 The seed search measured distance to each boundary edge's MIDPOINT. A side lying
      exactly along a rim is half a cell from every midpoint on it, so the search found nothing
      precisely when the answer was "this one" — `rimRun` returned nil and the whole
      continuation bailed. Now distance to the SEGMENT. (Caught by a direct probe of `rimRun`
      after the symptom — a single welded face — kept reappearing.)
- [x] 2.6 The weld named its new vertices by a live-vertex-id DIFF around `extendBoundary`.
      That is not a safe name for them, and welding off it collapsed the very patch it was
      meant to close (8 faces → 5). Now the rows are extruded ONE AT A TIME and each is welded
      by the `outerChain` the engine itself reports, with the next row stepped off where the
      welded row actually ended up.
- [x] 2.7 A single "how far off the rim may a side sit" tolerance cannot be right: it must be a
      small fraction of a long side and a large fraction of one cell. A fixed one either missed
      hand-drawn sides or swept in a PARALLEL rim a cell away. `rimRun` now runs two passes —
      generous, then refined against the cell the first pass measured.

## 3. Tests

- [x] 3.1 Controller `quadDrawnAlongASubdividedRimSharesEveryVertexOfIt`: an L tracing the two
      rims of an empty corner block creates 4 quads (2 rim cells x 2 rows), the interior rim
      vertex ends up in 4 faces, the patch closes onto the second rim (16 vertices, not 18),
      and one undo restores the payload bytes.
- [x] 3.2 Controller REGRESSION GUARD `oneCellAppendIsStillASingleFace`.
- [x] 3.3 `rimRunFindsTheChainASideFollows` — a direct unit test of the geometric trigger, the
      probe that found 2.5.
- [x] 3.4 Failing-first evidence, honestly scoped:
      - 2.5 (midpoint → segment seed): PROVEN. The direct `rimRun` probe returned
        `run → nil` and `chain → nil` for a side lying exactly on the rim; the same probe
        passes after the fix.
      - 2.6 (id-diff weld): PROVEN. With the diff-based weld the existing patch-fill test
        collapsed from 8 faces to 5; it passes with the `outerChain` weld.
      - 2.2 (corner gate → geometric trigger): NOT demonstrated by a failing test, and the
        attempt to demonstrate it is what showed why — restoring the old gate leaves the
        regression test PASSING, because that fixture's bend lands on an existing vertex and
        so satisfies it. The gate is still widened (a bend in open space would fail it), but
        this change's evidence for it is reasoning, not a red test.

## 4. Close out

- [x] 4.1 `openspec validate --all --strict`: 32/32.
- [x] 4.2 Simulator 1090/1090 + 462/462; device (iPad: RimBridgeOps, ContextAwareCreateFace,
      MeshEditController, PatchFill) 78/78.

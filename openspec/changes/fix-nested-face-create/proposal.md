# A face may never be created inside another face

## The report

A user's cage had several tiny faces stranded inside larger quads — a sliver triangle, a small quad,
a thin two-point sliver. The interpretation chip read `circle 0.83 on face → createQuad 0.33`.

That 0.33 is arithmetic, not noise: the circle path scores `0.4 × shapeConf` when the stroke is over
existing geometry, and 0.4 × 0.83 = 0.332. The closed-loop path scores `0.5 × shapeConf` the same way.

So **the recognizer already knew it was less certain and created anyway.** Down-weighting does not
prevent a bad create; it only makes it a low-confidence one.

## The invariant

A quad cage may have a face BESIDE another (sharing an edge) or replacing one. It may never have a
face floating INSIDE another: there is no shared topology, so the nested face is disconnected
geometry that no solver, unwrap or bake can make sense of.

That gives a test the recognizer can apply directly: if a closed stroke lies entirely within one
existing face and touches none of its topology, the create action is withheld — not scored lower.

## What "inside one face" has to mean

Two things had to be got right, and the first was wrong in my initial attempt:

- **Enclosure is the wrong test.** I first also required the stroke to enclose no faces. But a small
  loop near a big face's centre CONTAINS that face's centroid, so `facesEnclosed` reports the very
  face the loop is nested inside — rejecting exactly the case the check exists to catch. A test caught
  it. Containment of every sample is the real invariant and needs no enclosure test: a loop that
  genuinely encloses a face must leave that face's boundary, so it is not nested.

- **Touching topology must keep the create.** If any sample falls within pick range of an existing
  edge or vertex, the stroke shares topology and the create proceeds. That preserves drawing a quad
  against existing geometry — the grid continuation that shares a boundary — which is why this is a
  CONTAINMENT test rather than a blanket "never create over a face" rule.

## Why it belongs in the recognizer

The open-stroke create path already refused to create over an existing face (a centroid test added by
`add-context-aware-create-face`). The closed-loop and circle paths had no equivalent. So this closes an
asymmetry rather than inventing a rule: the same intent, applied to the paths that were missing it.

Withholding the candidate — rather than emitting it at zero confidence — means the stroke resolves to
"no match" and the chip says so, which is honest. A gesture that would produce invalid geometry should
report that it did nothing, not do something invalid quietly.

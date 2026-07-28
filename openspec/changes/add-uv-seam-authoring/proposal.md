# Hand-drawn UV seams (6.2, first slice)

## Why

One-tap unwrap (6.1) auto-seams. That is the right default and the wrong final answer: an
artist knows where a seam belongs — under an arm, along a hairline — and the automatic
chart growth does not. Until seams are authorable, the UV stage is take-it-or-leave-it.

## What already exists, and another estimate of mine to correct

I wrote in 6.1's scoping that "6.2 has no API to SUPPLY seams and no corner pinning."
**Half of that was wrong**, and in the same way 6.4's estimate was wrong — the engine had
more than I credited:

- **`SeamSet` exists** (`src/uv/include/cyber/uv/seams.hpp`) with `mark`, `erase`, `sew` and
  `toggle`, and its header already maps them onto the Pencil and Erase gestures.
- **`computeIslands(mesh, seams)` already honours a seam set**, treating a seam edge as
  uncrossable so a seam that rings a region cuts it into its own island.
- **`unwrapAtlas` already composes exactly the pipeline this needs**: `autoSeams` →
  `computeIslands` → LSCM per island → pack. The auto-seam step is the *only* thing standing
  between it and hand-drawn seams.

So the engine change is one field, not a subsystem. **Corner pinning, though, genuinely does
not exist**: `choosePins` selects two well-separated vertices automatically and no caller can
influence it. That half of the estimate stands, and it is split out below rather than bolted
on here.

## What changes

**Engine:** `AtlasOptions` gains an optional supplied seam set. When present, `unwrapAtlas`
uses it instead of calling `autoSeams`.

Supplied seams **replace** the automatic ones rather than adding to them. The alternative —
union — would cut where the artist did not ask, and "I drew three seams and got eleven" is
worse than a distorted result the report already warns about. `AtlasReport` closes that loop:
if too few seams leave the layout stretched, the max/RMS distortion and the new heatmap say
so, and the artist adds another seam. Predictability beats cleverness here.

**Document:** seams are document state — persisted, journaled, undoable — so they live in
`MeshAnnotations` beside tagged edges and frozen faces, and inherit persistence, id
compaction and one-undo behaviour rather than inventing a parallel mechanism.

**App:** a seam-authoring tool that toggles seams along a stroke (draw to cut, draw again to
sew, matching the engine header's own description), seams drawn distinctly in the overlay,
and unwrap honouring them.

## Non-goals, split out as 6.2b

- **Corner pinning.** Genuinely absent: the LSCM solver picks its own two pins. Letting a
  caller pin corners is real solver work — it changes which columns are eliminated — and it
  deserves its own change rather than riding along here.
- **The X-gesture unwrap.** A gesture-grammar addition on top of an unwrap action that now
  exists; independent of seams.
- **2D seam editing.** Seams are authored on the 3D surface here. Editing them in the 2D
  panel means picking edges in UV space and is part of 6.3's on-surface/2D manipulation work.

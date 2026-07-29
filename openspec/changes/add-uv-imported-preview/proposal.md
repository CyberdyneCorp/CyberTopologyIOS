# Imported-image preview and per-vertex UV editing (6.3d)

## Why

The last two fragments of 6.3's original text: judging a layout against real artwork rather than a
checker, and adjusting a single UV vertex rather than a whole island.

## A "UV vertex" is a cluster of corners, and that decides the whole design

UVs are per-corner, because a seam gives one vertex several different UVs. So "move a UV vertex" has
to mean something more careful than "move a corner": moving one corner of a welded group would **tear
the island at a point the artist never cut**.

The primitive therefore moves every corner in the island within a tolerance of the grabbed position.
Two things fall out of that, both for free:

- **Seams are preserved with no seam-specific logic.** Corners across a seam sit at different UVs by
  definition, so they fall outside each other's tolerance and move independently. That *is* what a
  seam is.
- **The comparison is against ORIGINAL positions**, collected before anything is written. Comparing
  against positions already updated mid-loop would let a moved corner drag a neighbour into range and
  move some corners twice.

A drag that matches nothing returns zero rather than an error: a near-miss is not an edit, and the
count is what the caller checks.

## Per-vertex is a MODE, not a zone

The 2D island grammar is positional (upper third rotates, lower scales, middle moves). Per-vertex
editing cannot join that scheme — it needs the whole island area available for picking a vertex, and
the thirds would eat two-thirds of the pickable surface. So it is a visible mode switch, and the mode
is captured at drag start alongside the transform mode, so switching it mid-drag cannot change what
the drag in flight is doing.

## The imported image extends the checker path rather than adding a second one

One pipeline, one shader, a uniform flag. Metal requires a texture at every declared binding, so a
1×1 placeholder is bound whenever no image is loaded — which keeps a single pipeline instead of a
second one that would drift from the first.

Details that are not incidental:

- **The image REPLACES the checker rather than tinting it.** Multiplying them would make a dark
  region of the artwork indistinguishable from a dark checker square.
- **v is flipped when sampling**, because image space runs top-down while UV runs bottom-up. Sampling
  unflipped would show every imported texture upside down against every other tool.
- **Repeat addressing**, because a UDIM layout deliberately puts islands outside the unit square and
  clamping would smear the edge pixel across all of them.
- **Texture mode with no image falls back to the checker**, rather than sampling the placeholder and
  painting the model one flat colour.
- **A failed load clears** any previous image, so the preview never shows one file while the UI names
  another.

A preview image journals NOTHING: it is view state, not document content, so it must not appear in
the undo stack. The import intent is therefore marked as not-a-mesh-import explicitly, because a
caller treating every completed import as a mesh import would add a phantom object for a texture.

## Found while building

`runMoveUVVertex` suppresses the status message when a drag matched no vertex — a near-miss is not
worth reporting, and doing so on every stray tap would bury the messages that matter. The first
version keyed that on `moved == 0`, which is ALSO true when the command was refused before it ran, so
it swallowed the legitimate "Unwrap first". Now it distinguishes "ran and matched nothing" from
"never ran", which a test caught.

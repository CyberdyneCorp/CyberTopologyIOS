# Symmetry-aware stacking and UDIM tiles (6.7)

## Why

Two texel-budget decisions an artist needs after unwrapping: whether a symmetric model's
left/right pairs share texture space, and which UDIM tile each shell belongs to.

## UDIM needs no document-model change, and that is the interesting finding

I had 6.7 recorded as needing a document-model change "since the atlas writes ONE UV set into
the unit square". True of UV sets. **Not true of UDIM tiles.**

A UDIM tile IS a region of UV space — tile 1002 is exactly `u ∈ [1, 2)`. So an island's tile is
derived from its UVs by construction, and storing an assignment beside them would create a
second source of truth that could disagree with the geometry. Worse, the disagreement would
only surface at export, when texture files come out named for tiles the UVs do not occupy.

So tiles are computed, never persisted. What was actually missing was three small queries and
one transform: which tiles are occupied (the list an exporter needs to name files), which
islands straddle a border, and move an island to a tile.

Straddling is surfaced rather than rounded away: an island spanning two tiles is split across
texture files, which is almost never intended and is invisible in the 2D view unless named.

## Stacking must match by geometry, not by island order

`cloneIslandUv` already exists and copies per-corner UVs between "topologically-matching"
islands — by island order, face order and corner index. That is unusable here:

- Island order out of `computeIslands` is an artifact of face-id iteration, so pairing islands by
  index would pair unrelated shells on any real model.
- Corner index across a mirror maps the wrong corners, producing a **scrambled shell that still
  looks plausible in the 2D view** — the worst kind of wrong, because the bounding box is right.

So pairs are matched by reflected face centroids, and corners by reflected vertex position. The
test asserts per-corner correspondence rather than matching bounding boxes, precisely because a
scrambled shell would pass a bounds check; mutating the implementation to index-matching fails it.

Tolerance is relative to each island's own size, so one value means the same thing on a fingertip
and a torso. An island lying ON the plane is not paired with itself — stacking one onto itself is
a no-op that would report false progress. A non-symmetric mesh yields no pairs, which is the
correct answer: a wrong pairing is far worse than doing nothing.

The plane comes from the DOCUMENT's symmetry state, never a default axis. That is the defect
`resymmetrize` already had to fix, where a radial-only or symmetry-off document was mirrored
about an axis the artist never enabled.

## Multiple UV sets is split out as 6.7a

Not deferred for size but for a specific blocker: **the document payload is OBJ**, which carries
exactly one UV channel (`vt`). So a second UV set cannot round-trip through a save at all.

Doing it properly means a sidecar file in the bundle (its `payloads` is a filename dictionary, so
this is feasible), a manifest field listing an object's sets, AND integration with
`MeshEditTransaction` — which pins the payload for byte-exact revert, so a sidecar outside it
would leave undo restoring geometry while losing UV sets. That is a document-model change of the
same class as 6.1a's project type, and it deserves its own change rather than riding along here.

The engine side is already scoped: `AttributeSet` supports arbitrarily-named columns, so sets can
live as `uv`, `uv:<name>` corner attributes with the active one always under `uv` — meaning the
entire UV module needs no change at all.

## Out of scope

- Multiple UV sets (6.7a, above).
- Per-island tile assignment UI beyond the readout; the panel names tiles and straddles, and the
  retile primitive is exposed but not yet gesture-driven.

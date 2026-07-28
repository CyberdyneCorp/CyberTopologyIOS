# Multiple UV sets (6.7a)

## Why

A game asset commonly needs more than one UV layout — one for textures, one for a lightmap — and
`uv-workflow` requires "multiple UV sets per mesh".

## The design that keeps the UV module untouched

Every UV operation in the engine reads the corner attribute named `uv`. So: **the ACTIVE set is
always that attribute**, and every inactive set is stored beside it as `uv:<name>`. Switching sets
swaps two columns.

The consequence is that the atlas, packing, distortion, transforms, stacking, UDIM — none of them
change at all, and none of them *can* read the wrong set. The alternative (threading a set name
through every function) would have touched every UV entry point and left a way to pass the wrong
one.

The active set's NAME is not stored in the mesh, because `AttributeSet` holds numeric columns only.
It lives on the C handle, and the engine functions take it explicitly — which also keeps them
testable by passing a name in.

## Persistence: a sidecar, and no schema change at all

The document payload is OBJ, which carries exactly one `vt` channel. So a second set cannot survive
a save through the payload.

`DocumentBundle.payloads` turned out to already read *every* file in the objects directory and to
explicitly tolerate extras for forward compatibility. So a `<uuid>.uvsets` sidecar persists with **no
manifest field and no schema-version bump** — and the filename is derived from the object id rather
than stored, for the same reason a UDIM tile is derived: a stored filename is a second source of
truth that can disagree with what it names.

Undo integration rides `DocumentCommand.compound`, which already exists to make geometry and
annotations one undo. A UV-set command journals the sidecar change and, when switching sets changed
the active layout, the resulting `meshEdit` — as one compound entry. Splitting them would let an undo
put the geometry's UVs back while leaving the set list naming a different active set, and the two
would disagree about which layout is current.

## Two defects found by testing, both about the same trap

**1. Every mesh edit was destroying stored UV sets.** A mesh edit re-serializes through the payload
by design — that is what makes revert byte-exact — and OBJ carries one `vt` channel, so the
round trip dropped every `uv:<name>` column. `DocumentBundle.mesh(for:)` restored the sidecar, but
the LIVE handle is built directly from payload bytes in three places, none of which did. Fixed by
putting the payload+sidecar pairing in a single `Mesh.fromPayload(_:uvSets:)` that every rebuild
goes through.

**2. A stale sidecar could resurrect an old layout over a newer edit.** The first version stored
the active set's data in the sidecar as well, "so the sidecar is self-describing". That created two
copies of the same layout, and on load the sidecar's copy overwrote `uv` — silently discarding every
UV edit made since the sidecar was written. Because of defect 1's round trip, that meant losing work
on the very next edit after any set existed.

The fix is the rule this codebase applies everywhere else: **one source of truth per fact.** The
payload owns the active layout; the sidecar owns the inactive sets and the active set's *name*. Both
defects now have regression tests, including one that edits after writing a sidecar and re-applies
the stale one.

## Refusals

- Creating a set requires an existing layout to COPY. An empty set would be a full column of (0,0),
  which reads downstream as a real layout collapsed at the origin.
- The ACTIVE set can never be deleted, which would leave the mesh with no layout.
- Names must be non-empty and must not contain `:`, the stored-column separator.
- A sidecar written for a different corner count is refused — a UV set on the wrong topology shears
  every island, which looks plausible and is wrong — but the document still OPENS: losing extra sets
  is recoverable, refusing to open over them is not.

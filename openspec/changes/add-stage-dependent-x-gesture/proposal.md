# Stage-dependent X gesture (6.2b)

## Why

The authoritative grammar says one shape means different things per stage: "X over
faces/region/component → delete (RT) / unwrap (UV) / bake (BK)". The recognizer already
emits `.cross`, and the app already maps it to `.deleteFaces`.

Nothing downstream knows what stage the document is in. `MeshEditController.Context` has no
stage field, and the only "stage" in the input path is the recognizer's own two-stage
pipeline, which is unrelated. So the mapping is unconditional.

**That is a destructive defect, not merely an unimplemented feature.** In the UV stage the
viewport stays fully interactive by design (`DocumentEditorView` keeps it live so the UV
tests can drive camera gestures on it). An X drawn there deletes faces from the cage the
artist is unwrapping. The spec says it should re-unwrap the island. A regression test comes
first, asserting the wrong behaviour is gone rather than asserting the new one works.

## What "unwrap the island" has to mean

6.1's unwrap is whole-mesh: it re-runs the atlas and repacks everything. Re-using it for an
X over one region would re-lay-out the entire model, which is the opposite of what a
localized gesture should do.

So this needs a per-island unwrap. The engine already has the pieces — `computeIslands`
partitions by seam set and `lscmUnwrap` + `writeIslandUv` unwrap one face set — but nothing
exposes "unwrap the island containing THIS face" through the C API.

### The island keeps its place in the atlas

An island re-unwrapped in isolation lands wherever LSCM puts it, at whatever scale the
conformal solve produces. Written back raw, it would overlap its neighbours and its scale
would no longer match theirs.

**Decided: the new parameterization is fitted back into the island's PREVIOUS UV footprint,
uniformly and centred.** Re-unwrapping then means "redo this island's internal
parameterization", leaving its place in the atlas alone — so it cannot disturb a layout the
artist arranged, and repeated X gestures on the same island are stable rather than walking it
across the square.

The fit is UNIFORM, and that detail is not cosmetic. Scaling to exactly FILL the old box means
scaling u and v by different factors whenever the new parameterization's aspect differs from
the old box's — a shear that destroys the conformality LSCM just solved for. The fit would be
undoing the computation it is placing. So the island is scaled by one factor to fit inside the
box and centred on the box's centre; when the aspect differs it occupies less than the full
box, which is correct rather than a shortfall.

**Rejected: `distributeIslandsUv`.** It exists and resolves overlaps correctly, but it
translates EVERY island onto fresh shelves. Using it here would let one localized gesture
rearrange the whole layout — precisely the failure mode this design avoids. It is the right
tool for 6.6's packing and for the double-tap distribution scenario, not for this.

### A never-unwrapped mesh takes the whole-mesh path, and that is not a shortcut

The obvious reading — "no previous box, so normalize into the unit square" — is a trap. UVs
live in ONE per-corner column, so creating it to write a single island zero-initializes every
OTHER island's corners. `uvCoordinates()` would then return a full non-nil stream, the 2D
panel would report `.laidOut`, and every island the artist has not X'd would be drawn
collapsed at the origin: a layout that looks real and is not. That is precisely the
absence-versus-zero failure the UV path is careful about everywhere else.

So the engine primitive REQUIRES existing UVs and refuses otherwise, and the app decides the
policy: no UVs yet means the X runs the whole-mesh unwrap; UVs present means it re-unwraps the
one island. Keeping the refusal in the engine and the policy in the app means the primitive
cannot be misused into producing a half-initialized column, and the artist's first X in the UV
stage still does the useful thing.

## Scope correction: corner pinning is not part of this

The 6.2b task text I wrote says corner pinning is "real solver work" because `choosePins`
takes no caller input. The premise is true, but the conclusion does not follow from the
spec — I checked, and **no requirement asks for artist-specified pins.** The only pinning in
the authoritative spec is parenthetical, inside the on-surface relax requirement: "relax an
island's UVs by scrubbing on the 3D surface (corner auto-pinning)". Auto-pinning is what
`choosePins` already does.

So artist-specified pins were scope I invented and then carried as if the spec required it.
Removed from 6.2b rather than built. The auto-pinning the spec does ask for is part of the
relax scrub in 6.3, where it belongs.

This is the fourth scoping correction in Phase 6, and the first in this direction — the
other three undersold the engine; this one overstated the requirement.

## Out of scope

- **Bake on X (BK stage).** Phase 7. The stage routing is written so adding it is one case.
- **Whole-mesh repacking after a re-unwrap.** 6.6.
- **2D-side X gestures.** The 2D panel has no gesture surface yet; that is 6.3.

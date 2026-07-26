# Proposal: add-weave-region-selection

## Why

`add-weave-regional-solve` built regional prescribed-boundary solve end to end —
engine, C API, CyberKit, and `beginAutoRetopo(region:)` — and proved exact landing
at 1× and 4× density on four fixtures. **It has no user.** Nothing in the app
produces a face selection, so `region:` is only ever `.wholeMesh` and every line of
that work is dormant.

This change gives it one, and in doing so turns Auto-Retopo from a one-shot
whole-Target button into the interactive loop the weave-solver spec describes:
select a patch, solve it against its frozen neighbours, adjust, re-solve.

## What Changes

- **A `weaveRegion` armed tool.** A Pencil stroke PAINTS over the faces to
  re-weave; a second stroke adds to the selection; the banner shows the count and
  the density the solve will use. Arming, selection and commit reuse the
  `RetopoTool` + tool-session machinery Patch Clone already uses.
- **Region solve runs on the EDITMESH, not the Target.** See Design Decision 1 —
  this is the change's load-bearing choice and it is not what "Auto-Retopo" does
  today.
- **Solve, review, accept.** The armed selection solves through
  `CompositeWeaveSolver` into the existing amber ghost + Accept/Discard bar, with
  the region notice (irregular interface vertices, seam triangles) already wired in
  task 13.3.
- **Live re-solve on constraint edit.** While a region session is armed, changing
  the density preset or the selection re-runs the solve and replaces the ghost,
  debounced, without journaling anything.

## Impact

- Affected specs: `weave-solver` (ADDED: region selection is an armed tool, region
  solve targets the EditMesh, live re-solve, selection is not journaled).
- Affected code: `RetopoTool.weaveRegion` + `EditorAction`; a `WeaveRegionSession`
  on `MeshEditController`; `AutoRetopoSession` gains a region entry point;
  `CameraToolBannerView` / `AutoRetopoBannerView` copy; `ActionCatalog` entry.
- Affected tests: selection accumulation and clearing, solve-on-armed-selection,
  re-solve on density change, accept journals exactly once and undoes byte-exactly,
  discard journals nothing, and a UI test driving the real tool.

## Non-Goals (deferred)

- **A lasso ENCLOSURE gesture.** Explicitly not this. See Design Decision 2.
- **Target-snapping for a re-woven region.** See Design Decision 3 — a real
  limitation this change does not fix, and the reason a re-woven patch follows the
  cage rather than the Target.
- **Frozen-patch AUTHORING** (5.2a's app half): the region's complement is frozen
  implicitly by not being selected; there is no separate "freeze this" state yet.
- In-viewport accept/discard gesture shortcuts, and a progress percentage — both
  already deliberately deferred in 5.4a.

## Design Decision 1 — the region is a region of the EditMesh

Auto-Retopo today solves the **Target** (high-poly) into a **new EditMesh**. A
region solve cannot work that way: the region path keeps the complement FROZEN and
byte-identical, so region-solving a Target would return the whole multi-million-
triangle Target with one patch quadrangulated inside it.

The operation that makes sense — and the one the prescribed-boundary guarantee was
built for — is **re-weaving a patch of the existing quad cage against its frozen
neighbours**. That is also what makes the accept sane: the frozen part of the
result is bitwise identical to the current EditMesh, so accepting changes only the
patch the user selected.

Consequence worth stating plainly: this change introduces an Auto-Retopo mode whose
INPUT is the EditMesh. The whole-mesh mode still reads the Target. Two modes behind
one action is a real UX cost, and the banner must make which one is running obvious.

## Design Decision 2 — painted selection, not a lasso

5.4a says "lasso-region solve UX". **Implementing that literally would reintroduce
a gesture this project already removed on measured evidence.**
`simplify-gesture-grammar` cut the lasso from the Pencil grammar because on-device
testing showed a closed quad stroke with a slight overshoot classified as `lasso`
→ `hideRegion`; the retired entry in `ActionCatalog` records that the capability
"returns as an armed tool".

So the selection is a PAINTED stroke over faces on an ARMED tool, resolved through
the same `strokeSurfaceHits` path Patch Clone uses. No shape classification is
involved, so there is nothing to misread. This also composes better: painting adds
to a selection incrementally, where a lasso is all-or-nothing.

The task wording should be read as "a way to select a region", not "the lasso
shape". 5.4a is updated to say so.

## Design Decision 3 — a re-woven region follows the CAGE, not the Target

`remeshRegion` builds its `ReferenceSurface` from the working mesh, which under
Decision 1 is the EditMesh. So the re-woven patch is projected back onto the cage's
own surface, not onto the Target the cage approximates. On a coarse cage that loses
surface fidelity exactly where the user asked for more topology.

This is NOT fixed here, and it is the main reason to treat this change as the first
usable slice rather than the finished feature. Fixing it needs the region path to
accept an external reference surface — an engine change (the `ReferenceSurface` is
constructed inside `remeshRegion`) plus a C API parameter. Split out as **5.4b**.

## Notes

Nothing about the solver changes. This change is selection, session and
presentation over the API `add-weave-regional-solve` already shipped, which is why
its risk sits in UX and state lifetime rather than in geometry.

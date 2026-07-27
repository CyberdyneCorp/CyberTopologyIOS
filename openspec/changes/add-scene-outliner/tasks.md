# Tasks: add-scene-outliner (8.1)

Document-model change first, UI last — the state and its refusals are what make the
outliner real, and they are testable headless. No engine work at any point.

## 1. Document model

- [x] 1.1 `DocumentManifest.Object` gains `isHidden`, `isLocked` and `group`, with an
      EXPLICIT `init(from:)` using `decodeIfPresent`. The hazard was real and slightly
      narrower than written: Swift's synthesized conformance already decodes OPTIONAL
      properties with `decodeIfPresent` (which is why `counts` and `annotations` survived
      their own schema bumps), but `isHidden`/`isLocked` are non-optional `Bool`s and would
      therefore have been REQUIRED, throwing `keyNotFound` on every existing document —
      exactly `DensityField`'s 5.2b failure. Asserted by a test that decodes a manifest
      entry containing only the pre-8.1 keys.
- [x] 1.2 A `Bool`/`String?` default must also mean the pre-8.1 behaviour: absent ⇒ visible,
      unlocked, ungrouped.
- [x] 1.3 Tests: round-trip; a document written WITHOUT the new keys still decodes; defaults
      are the old behaviour.

## 2. Journaled commands

- [x] 2.1 `DocumentCommand.objectStateEdit` carrying before/after so undo is exact, covering
      visibility, lock, group and name. One case rather than four: they are all the same
      kind of manifest-entry change, and four cases would mean four apply/revert paths to
      keep consistent.
- [x] 2.2 Solo is NOT journaled. It is a view mode; journaling it would put a camera-like
      action in the undo stack and, worse, require storing "everything else hidden", which
      destroys the artist's real visibility state.
- [x] 2.3 Tests: each state change is exactly ONE undo step and reverts precisely; solo
      leaves the journal untouched.

## 3. The lock guarantee

- [x] 3.1 Refused in `TopoDocument.perform`, the single point every NEW command passes
      through, via `DocumentCommand.payloadMutatedObjectIDs`. Deliberately NOT in
      `DocumentCommand.apply`, which is also the undo/redo and journal-REPLAY path: history
      must replay faithfully, and an object locked AFTER an edge was moved must not
      retroactively make that edit unreplayable. `compound` reports the UNION so a batch
      containing one locked member is refused whole rather than half-applied, and the
      refusal is surfaced as a notice because silently dropping a stroke reads as a broken
      app.
- [x] 3.2 Locking must NOT restrict viewing, measuring, soloing or renaming — those are not
      payload changes.
- [x] 3.3 Tests: a mesh edit against a locked object is refused AND the payload is
      byte-unchanged; renaming a locked object succeeds.

## 4. Visibility composition

- [x] 4.1 Renderer draws an object's geometry only when the object is visible AND the face
      is not hidden. Object-level hiding dominates and must not rewrite face state.
- [x] 4.2 Solo treats every non-soloed object as hidden without touching stored visibility.
- [x] 4.3 Group hide/show applies to members without rewriting each member's own
      `isHidden`, for the same reason solo does not: un-hiding the group must restore what
      the artist had per object.
- [x] 4.4 Tests: hidden object draws nothing; show-after-hide restores the exact face
      state; solo then un-solo restores per-object visibility exactly.

## 5. Outliner UI

- [x] 5.1 List objects with role, name and counts; unknown counts shown as unknown, never 0.
- [x] 5.2 Per-row show / solo / lock affordances, and rename.
- [x] 5.3 Grouped objects presented together with a per-group show/hide.
- [x] 5.4 Reached like every other non-default action, through the Action Gallery, so it
      costs no default toolbar slot.

## 6. Close out

- [x] 6.1 `openspec validate --changes --strict`; full simulator suite; device run of the
      new suites; engine suite unaffected (no engine change in this task).
- [x] 6.2 Update the master 8.1 entry with what shipped and what was deliberately excluded
      (no scene graph, no per-object transforms, no multi-object editing).

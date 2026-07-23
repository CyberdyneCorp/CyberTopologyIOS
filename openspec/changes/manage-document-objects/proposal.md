# Proposal: manage-document-objects

## Why

Device testing surfaced two gaps in how a document's objects are managed:

- **Re-importing a Target stacks a second one.** `importCommand` always
  emits `addObject`, so importing a Target while one already exists leaves
  the document with two Targets overlapping in the viewport. The intended
  workflow is to swap the reference model — the new import should REPLACE the
  current same-role object, not accumulate.

- **There is no way to remove an object.** Once a Target or EditMesh is in
  the document it is permanent: no delete affordance exists, and the
  undo-journal has no `removeObject` command. A mis-imported Target, or an
  EditMesh the user wants to start over, cannot be cleared.

## What Changes

- **Add a `removeObject` command** to the undo journal (data model): the
  exact inverse of `addObject`, carrying the manifest entry and payload bytes
  so undo restores the removed object verbatim.
- **Re-import replaces the same-role object.** When a Target (or EditMesh) is
  imported and one of that role already exists, the import resolves to a
  single undoable step that removes the old object and adds the new one
  (`compound([removeObject, addObject])`). Import into an empty slot is
  unchanged (a plain `addObject`).
- **Delete affordance in the object list.** Each object row gains a delete
  control that removes that object in one undoable step. Deleting a Target
  leaves any EditMesh untouched (they are independent objects); deleting an
  EditMesh leaves the Target.

## Impact

- Affected specs: `document-model` (object removal + single-instance import
  replacement).
- Affected code: `DocumentCommand` (+`removeObject`, apply/revert/
  resultingPayload), `DocumentBundle.importCommand` (replace resolution),
  a `removeObjectCommand` helper, `TopoDocument`, `DocumentEditorView`
  (object-list delete control), and the import handler.
- Affected tests: import-replace (re-import yields one object; undo restores
  the previous one), delete + undo round-trips, and the anti-vacuity case
  (import into an empty slot still adds).

## Notes

The `document-model` capability still permits multiple objects at the data
layer (the manifest is a list, and the journal replays either direction).
This change constrains only the IMPORT ACTION to single-instance-per-role,
which is the shipping app's one-Target/one-EditMesh workflow; an outliner
that deliberately manages several objects (task 8.1) can add objects through
a different path without contradicting this.

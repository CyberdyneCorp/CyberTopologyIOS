# Tasks: manage-document-objects

## 1. Data model: removeObject command

- [x] 1.1 Add `DocumentCommand.removeObject(object:payload:)`: `apply`
      removes the manifest entry + payload; `revert` restores both. Mirror
      `addObject` exactly (it is the inverse). Extend `resultingPayload` (no
      geometry result → nil).
- [x] 1.2 `DocumentBundle.removeObjectCommand(id:)` helper: builds a
      `removeObject` carrying the current object + payload; nil for an
      unknown id.

## 2. Import replacement

- [x] 2.1 `importCommand` resolves to `compound([removeObject(existing),
      addObject(new)])` when an object of the imported role already exists;
      a plain `addObject` when the slot is empty. One undoable step either
      way.

## 3. Delete UI

- [x] 3.1 Object-list rows gain a delete control (accessibility id per row)
      that performs the object's `removeObject` command through the document
      (journaled, undoable).

## 4. Tests

- [x] 4.1 removeObject apply/revert round-trip (byte-exact payload restore).
- [x] 4.2 Re-importing a same-role object yields exactly one of that role;
      one undo restores the previous object.
- [x] 4.3 Import into an empty slot still adds (anti-vacuity); one undo
      removes it.
- [x] 4.4 Delete Target leaves EditMesh (and vice versa); one undo restores.
- [x] 4.5 App-level: the delete control removes the row and journals one
      undoable entry.

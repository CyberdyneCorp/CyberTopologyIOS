# Scene outliner: show / solo / lock, groups, per-object stats (8.1)

## Why

Phase 8's first task, and the largest remaining item with **no engine dependency at all** —
everything it needs is already in the document manifest or derivable from it. That is why
it is worth doing before the rest of Phase 8, whose importers and exporters each need real
format work.

Today a document is a flat list of objects with a `role` (`target` / `editMesh`), a name,
and optional `counts`. There is no way to hide an object, protect one from editing, or
group several — so a document with a Target, a working EditMesh and two accepted retopo
variants offers no way to compare them or to stop editing the wrong one.

## What already exists, and what does not

Worth stating precisely so the change does not rebuild what is there:

- **`Object.counts`** (vertices, faces) is already captured at import time, specifically
  so the UI never deserialises a payload to show numbers. Per-object stats are therefore a
  READOUT, not a computation.
- **`MeshAnnotations.hiddenFaces`** already gives PER-FACE visibility, driven by the 3.4
  lasso. Object-level visibility is a different axis and must compose with it rather than
  replace it.
- **`DocumentCommand`** already has `addObject` / `removeObject` / `meshEdit` /
  `annotationEdit` / `setSymmetry`, all journaled, so undo comes for free once the new
  state changes through a command of its own.
- **Nothing** carries object visibility, lock state, or grouping. That is the new state.

## The composition rule this change has to answer

Object visibility and lasso visibility are independent, and "hidden" must mean the same
thing to the renderer either way. The rule: **an object contributes geometry only when the
object is visible AND the face is not hidden.** Object-level hiding therefore dominates —
it cannot be partially overridden by face state — while a visible object still honours
whatever the lasso did to its faces.

SOLO is a view mode, not per-object state stored N times: soloing object A means every
other object is treated as hidden without their own `isHidden` being rewritten, so
un-soloing restores exactly what the user had. Storing solo as "hide everything else"
would destroy that.

LOCK protects against EDITS, not against selection or visibility: a locked object can be
looked at, measured and soloed, but no journaled command may modify its payload. Refusing
at the command layer rather than by disabling buttons is what makes it real — a disabled
button is a UI convention, an enforced refusal is a guarantee.

## Non-goals

- **Reordering / reparenting as a scene graph.** Groups here are a flat label, not a
  transform hierarchy. A real hierarchy implies inherited transforms, which the document
  model has no notion of and which no Phase 8 task asks for.
- **Multi-object editing.** The verbs act on the active EditMesh; the outliner changes
  which object that is, not how many are edited at once.
- **Per-object transforms.** Objects share one world space today; giving each a transform
  is a document-model change with export consequences well beyond an outliner.

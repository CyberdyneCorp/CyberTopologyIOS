# UV-only projects and split-view gestures (6.1a)

## Why

An artist with an existing low-poly and no high-poly reference should be able to open it and
unwrap it. That is the "UV-only workflow" the competitor analysis records as missing from
CozyBlanket, and it is the last piece of 6.1's original text.

## The "project type" is a derived behaviour, not a document type

My 6.1a task text said: "The project type is a document-model and document-browser change with
its own import path." **That was wrong.** The authoritative requirement
(`document-model/spec.md`) is:

> **WHEN** a user creates a UV-only project by importing a low-poly mesh as the EditMesh with no
> Target **THEN** the document SHALL open directly in the UV stage with snapping disabled and all
> UV and export features functional

No second UTI, no separate browser entry, no manifest field. "A UV-only project" is exactly
"an EditMesh and no Target" — derived, the same way a UDIM tile is derived from where an island's
UVs are. A stored flag would be worse than useless: removing a document's Target must make it
behave as UV-only, which a flag would not survive.

Two of the three parts already held before this change:

- `importMesh(at:role:)` already takes a role, so importing as the EditMesh needed no new path.
- `targetSnapper` is already nil when the document has no Target
  (`MetalViewport.syncTargetSnapper`), so **snapping is already disabled** with nothing to add.

What was actually missing: opening in the UV stage, and a verified claim that no UV or export
feature requires a Target. The import is a COMPOUND command — the object and the stage switch as
one undo — because two commands would leave an undo that removed the mesh while stranding the
document in a UV stage with nothing to unwrap.

## The layout gesture belongs on the panel, and a UI test proved it

First attempt attached the swipe/line gesture to the container holding both views. That broke
`testCameraGesturesDoNotConflictWithUndoTaps` — verified as caused by the change, not
pre-existing, by re-running it on the untouched tree. A SwiftUI `DragGesture` on an ancestor of a
`UIViewRepresentable` competes with the representable's UIKit recognizers, so the viewport's
camera gestures stopped behaving.

The fix is structural rather than a tuned threshold: the gesture lives on the **2D panel**, which
has no camera recognizer. Nothing is lost, because in every reachable state the surfaces the
gesture needs are over the panel — the trailing screen edge always is, and when the panel is
maximized the screen middle is too. Every touch that starts over the 3D view stays with the
camera.

Two further rules fall out of that:

- **A divider line is only claimed when a pane is maximized.** In the split state there is nothing
  to restore, and claiming the drag would swallow one the island grammar could use.
- **The panel never collapses to nothing.** With the viewport maximized the panel keeps an 18pt
  grab strip, because a hidden panel would take its own gesture surface with it — making that
  state enterable with one swipe and impossible to leave.

Maximizing is done by SIZING, never by re-parenting: `DocumentEditorView` already documents that
moving the viewport between containers gives it a new SwiftUI identity and re-creates the
coordinator. A zero-width viewport is safe because `setViewportSize` ignores a non-positive size.

## Out of scope

- A "new UV-only document" template in the document browser. The spec describes an IMPORT, and an
  empty UV-only document has nothing to unwrap.

# Hovering highlights the element a Move drag would grab

## Why

Asked on device, straight after context-aware Move shipped: *"When we hover a face, vertex,
edge-loop can we highlight it? vertex (yellow, as it is now), face (pink), edge-loop (red)."*

Move's scope is now decided by what is under the finger, and that decision turns on distances
as small as 0.15 of a cell. Today the artist finds out which scope they got by watching the
mesh change — the chip names it only once the drag is already live. Hovering is the moment
before commitment, and it is exactly where the answer belongs.

Two gaps stand between here and that:

- **A hovered FACE previews nothing.** Hover resolves a snap vertex, a slide loop, or a ghost
  quad over empty surface. Over the interior of an existing face — the surface-scope drag,
  the most common Move — nothing appears.
- **Hover and Move disagree about what is under the pointer.** Hover picks with
  `0.05 × sceneRadius` for a vertex and `0.07 × sceneRadius` for an edge; Move picks with
  `0.25` and `0.15` of the LOCAL CELL. On a cage of 1-unit cells in a scene of radius 7 that
  is an edge window of 0.49 against Move's 0.15 — so a highlight would say "loop" over ground
  where the drag stretches the patch. A highlight that predicts the wrong thing is worse than
  none: it teaches a rule the tool does not follow.

## What Changes

- **One rule decides what is under the pointer.** `MeshEditController.resolveMoveScope` — the
  function Move already uses — becomes the source of truth for the hover element queries too,
  so the highlight and the drag can never disagree.
- **A hovered face highlights** as a translucent PINK fill, through the existing ghost
  pipeline (which already carries a per-style colour), non-pulsing so it reads as a statement
  of fact rather than an invitation.
- **The edge loop highlights RED**, the whole loop the drag would carry.
- **A vertex stays YELLOW**, unchanged.
- **A boundary edge now highlights too.** The loop query used to reject boundary edges as "not
  slidable"; Move grabs them (degrading to the edge's own vertices), so the highlight follows
  Move. The double-tap slide keeps its own rule — this changes what is SHOWN, not what a
  double-tap does.

Non-goals: no change to what any drag does; no highlight for the falloff REGION a surface drag
carries (the hovered face is the statement, not the blast radius); no hover for the camera
tools; and no new colour settings — the three colours are fixed, as the wireframe and pin
colours are.

## Capabilities

### New Capabilities

- `pencil-interaction`: hovering previews the element a Move drag would grab, colour-coded by
  scope, resolved by the same rule the drag uses.

## Impact

- **Affected specs**: `pencil-interaction` (ADDED requirements). The hover-preview requirement
  from the original app change gains a face case and a colour contract.
- **Affected code**: `App/Sources/HoverPreview.swift` (new preview case, queries backed by
  `resolveMoveScope`), `App/Sources/MeshEditController.swift` (`MoveScope.loop` carries its
  seed edge so hover can walk it), `App/Sources/EditMeshOverlay.swift` +
  `App/Sources/ViewportRenderer.swift` (per-element highlight colour, pink face style).
- **Risk**: hover picking changes for every verb, not just Move — the windows get TIGHTER, so
  a hover that used to preview a loop from 0.49 world units away now needs 0.15 of a cell.
  That is the point (it is what the drag does), but it is a visible change to a shipped
  affordance, and the boundary-edge rule changes with it.

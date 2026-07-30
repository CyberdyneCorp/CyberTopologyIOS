# Proposal: add-stroke-rim-bridge

## Why

Device testing on 2026-07-29 (iPad Air 13-inch M3, 49v/34f cage over a 121v Target)
showed a stroke drawn ACROSS AN UNFILLED GAP — from a vertex on one open rim, over bare
Target, to a vertex on the rim facing it — resolving to a loop insert:

```
line 0.97 on emptySurface; insertLoop:0.73 [edge:31,edge:33]
```

Two things are wrong with that. The gesture inserted a loop into a ring the stroke only
CLIPPED at its two endpoints, so the cage gained a loop nowhere near where the user drew.
And the thing the user was asking for — quads across the gap — is the single most common
move in manual retopology and the grammar has no way to express it: the near-straight
branch of `tryOpenStrokeCreateFace` deliberately returns "no face", so the stroke fell
through to the Line branch, whose only rule is `insertLoop`.

Loop insert IS the right reading for the OTHER stroke in the same session — one drawn
across a group of faces, which is the kept LoopCut gesture. What separates the two is not
the shape (both are near-straight lines between two vertices) but WHAT IS UNDER THE
STROKE: faces, or a gap between two rims.

## What Changes

- **A near-straight stroke between two boundary vertices over empty surface bridges the
  two facing rims.** The stroke's endpoints name one corresponding pair; both rims are
  then walked outward from that pair and each paired step emits one quad, so the whole
  corridor between the two rims fills — not just the part the stroke covered. The bridge
  quads reuse the existing rim vertices, adding none of their own along the rims.
- **The bridge is subdivided across the gap** so its quads stay roughly cage-sized:
  the number of rows is the gap width in mean rim cells, and the interior rows' new
  vertices are snapped onto the Target.
- **Loop insert now requires the line to actually run over faces.** A line whose samples
  never pass over a face no longer offers `insertLoop`, which is what let a gap-crossing
  stroke insert a loop into a ring it merely clipped at its endpoints.
- **BREAKING (grammar)**: the pencil-interaction requirement "A straight stroke makes no
  face" is narrowed — a straight stroke over empty surface between two RIM vertices now
  creates bridge quads. A straight stroke that is not between two rim vertices, or that
  runs over faces, still creates no face.
- New grammar action `bridgeRims` across the engine recognizer, the C ABI, CyberKit, and
  the interpretation chip.

Non-goals (deliberately out of scope):

- **Symmetry.** A symmetric bridge needs the mirrored rim PAIR resolved, not two
  independent mirrored vertices; the primary bridge only is applied, as with the mirror
  side of `insertLoop` before task 4.4a.
- **Bridging across two separate objects.** Both rims must belong to the one EditMesh.
- **Curved / multi-turn strokes.** A bent stroke between two vertices keeps its existing
  quad/triangle create reading.

## Capabilities

### New Capabilities

None — this extends the existing Pencil grammar.

### Modified Capabilities

- `pencil-interaction`: adds the rim-bridge requirement, narrows the existing
  "a straight stroke makes no face" requirement, and states the new
  faces-under-the-stroke condition on loop insert.

## Impact

- `Engine/CyberRemesherAndUV/src/retopo/include/cyber/retopo/stroke_interpreter.hpp` —
  new `InterpretedAction::BridgeRims`, the rim-bridge rule, the loop-insert gate.
- `Engine/CyberRemesherAndUV/capi/{include/cyber_capi.h,src/capi.cpp}` —
  `CYBER_ACTION_BRIDGE_RIMS`.
- `CyberKit/Sources/CyberKit/StrokeInterpretation.swift` — `Action.bridgeRims`.
- `CyberKit/Sources/CyberKit/MeshRimBridge.swift` (new) — the rim walk, pairing and quad
  emission, composed from existing engine ops (`boundaryChain`, `buildFace`).
- `App/Sources/MeshEditController.swift` — applies the candidate as one journaled
  command; `App/Sources/InterpretationChip.swift` — the chip label.
- Tests: engine-recognizer grammar tests, a CyberKit op suite (mirrored into the
  app-hosted target so it runs on device), and a controller apply test.

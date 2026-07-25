# Design: add-guide-stroke-authoring

## Context

The Weave solver honours orientation guides (`WeaveConstraints.guideStrokes`), but
nothing authors them. This change adds capture (draw on the Target), a Metal line
overlay to show them, and wiring into Auto-Retopo. The steering math is unchanged.

## Capture — a Guide tool (mirrors Pin Flip)

`MeshEditController` already routes pencil strokes to an armed `RetopoTool` and pins a
`toolStroke` at begin, committing at end with the full sample polyline. A new
`.guide` tool rides this path:

- **Begin gate:** guide needs only a Target snapper (no EditMesh), unlike the geometry
  tools — a special case in `strokeBegan` pins the `toolStroke` when `context.snapper`
  is present.
- **Commit:** `commitToolStroke`'s `.guide` case raycasts each sample onto the Target
  (`surfacePoint(at:in:)`, the existing raycast) into a world-space polyline and
  appends it to `authoredGuides`. A stroke that hits nothing (empty polyline) stores
  no guide. Journals nothing — guides are authoring state, not document edits.
- **Storage:** `authoredGuides: [[SIMD3<Float>]]` on the controller, plus
  `clearGuides()` and an `onGuidesChanged` callback the coordinator uses to refresh the
  overlay.

## Rendering — `GuideLineRenderPath` (mirrors `GhostRenderPath`)

Shaders are inline MSL compiled at runtime (the established pattern — no `.metal`
file). The path mirrors `GhostRenderPath` with these differences:

| Aspect | GhostRenderPath | GuideLineRenderPath |
|---|---|---|
| Primitive | `.triangle` | `.line` (segment index pairs) |
| Buffers | positions + normals | positions only |
| Uniforms | mvp + color + viewDir + params | mvp + solid amber color |
| Depth | `.lessEqual`, write OFF | same (depth-tested, occluded by geometry) |
| Zero-copy | full machinery | dropped (guides are transient app arrays — always pooled copy) |

Line geometry: each guide polyline of N points → N-1 segments → index pairs
`[0,1, 1,2, …]`, one shared position buffer across all guides. Amber = the existing
`GhostStyle.proposal.color` (1.0, 0.62, 0.24).

Integration in `ViewportRenderer`: a `guideLinePath` property built in `init?`;
`loadGuideLines(positions:indices:)` / `clearGuideLines()` (each calls `invalidate()`);
encoded in `encodeFrame` after the wireframe overlay (top of the overlay stack);
added to the early-out guard. NOT added to `isAnimating` — guides are static, so they
must not pin the display link at 120 Hz.

Coordinator: a `syncGuideLines` method (mirroring `syncGhostPreview`) flattens
`authoredGuides` into a shared position buffer + line-index pairs and calls
`loadGuideLines`; called on `onGuidesChanged` and mesh re-sync.

## Wiring into Auto-Retopo

`beginAutoRetopoAsync` builds `WeaveConstraints(guideStrokes: authoredGuides.map {
GuideStroke(points: $0) })` alongside the existing symmetry. With no guides the
constraint set is empty and the solve is unchanged (already spec-covered).

## UI

- A **Guide** entry in the tool roster (`RetopoTool.guide` + an `EditorAction`) to arm
  guide mode; arming routes strokes to capture.
- A **Clear Guides** action.

## Key decisions

### D1 — Guide is a tool, not new arbiter surgery
Riding the existing armed-tool stroke path (like Pin Flip) means no changes to
arbitration — arming `.guide` intercepts pencil strokes cleanly, and the grammar is
bypassed exactly as it is for any armed tool.

### D2 — Session state, not document state
Guides are transient authoring hints (like a camera pose), stored on the controller
and cleared on demand — not journaled, not persisted. Document persistence is a
named non-goal.

### D3 — Reuse the raycast + ghost render conventions
Capture reuses `surfacePoint` (the same raycast the brushes use); rendering reuses the
`GhostRenderPath` buffer/encode/invalidate conventions, so the new surface is small
and consistent.

## Risks / Trade-offs

- **Line rendering is the largest new surface** — a Metal pipeline; de-risked by
  mirroring `GhostRenderPath` and testing headlessly (offscreen render → amber-pixel
  classification, the existing ghost-test pattern).
- **Depth-test occlusion** — guides write no depth and are `.lessEqual` tested, so they
  sit on the Target and are hidden behind it when it faces away (correct for a surface
  overlay).
- **No per-guide edit** — draw-and-clear only; individual guide management deferred.

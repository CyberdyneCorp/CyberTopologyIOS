# Tasks: add-guide-stroke-authoring

## 1. Capture — Guide tool

- [x] 1.1 `RetopoTool.guide` (+ `isCameraManipulator` = false).
- [x] 1.2 `strokeBegan`: special-case guide — pin the `toolStroke` when a Target
      snapper is present (no EditMesh required).
- [x] 1.3 `commitToolStroke` `.guide` case: raycast each sample onto the Target
      (`surfacePoint`) → world polyline; append to `authoredGuides`; a miss stores
      nothing; journals nothing.
- [x] 1.4 `MeshEditController.authoredGuides: [[SIMD3<Float>]]`, `clearGuides()`,
      `onGuidesChanged` callback.

## 2. Rendering — GuideLineRenderPath

- [x] 2.1 `App/Sources/GuideLineRenderPath.swift`: mirror `GhostRenderPath` — inline
      MSL shader (mvp * position; solid amber fragment), `.line` primitive, positions
      only, no zero-copy; alpha blend; depth `.lessEqual` write-off. `GuideLineUniforms`
      + factory.
- [x] 2.2 `ViewportRenderer`: `guideLinePath` property; `loadGuideLines(positions:
      indices:)` / `clearGuideLines()` (each `invalidate()`); encode after the wireframe
      overlay; add to the early-out guard; NOT in `isAnimating`.

## 3. Wire guides → overlay + Auto-Retopo

- [x] 3.1 Coordinator `syncGuideLines`: flatten `authoredGuides` → shared positions +
      line-index pairs → `loadGuideLines`; called on `onGuidesChanged`.
- [x] 3.2 `beginAutoRetopoAsync`: add `guideStrokes: authoredGuides.map { GuideStroke(
      points: $0) }` to the constraints. Empty ⇒ unchanged solve.

## 4. UI

- [x] 4.1 A Guides menu with Draw Guides (arms `.guide` via `armGuideMode`, toggles
      to Stop) — menu-driven rather than a toolbar-slot tool, so no EditorAction.
- [x] 4.2 A Clear Guides control (disabled when no guides).

## 5. Tests (device + simulator)

- [x] 5.1 Capture: a guide stroke over the Target yields a world polyline on the
      surface; a stroke missing the Target yields no guide; clear empties them.
- [x] 5.2 `GuideLineRenderPathTests`: load/hasGeometry/clear; headless offscreen render
      shows amber pixels (`classifyAgainst`); no realloc on same-size reload.
- [x] 5.3 Auto-Retopo threads authored guides into the solve; with none, unchanged.

## 6. Validation

- [x] 6.1 `openspec validate add-guide-stroke-authoring --strict`.
- [x] 6.2 Full suite green on simulator (743). Device run pending an unlocked iPad.

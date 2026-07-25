# Tasks: add-guide-stroke-authoring

## 1. Capture — Guide tool

- [ ] 1.1 `RetopoTool.guide` (+ `isCameraManipulator` = false).
- [ ] 1.2 `strokeBegan`: special-case guide — pin the `toolStroke` when a Target
      snapper is present (no EditMesh required).
- [ ] 1.3 `commitToolStroke` `.guide` case: raycast each sample onto the Target
      (`surfacePoint`) → world polyline; append to `authoredGuides`; a miss stores
      nothing; journals nothing.
- [ ] 1.4 `MeshEditController.authoredGuides: [[SIMD3<Float>]]`, `clearGuides()`,
      `onGuidesChanged` callback.

## 2. Rendering — GuideLineRenderPath

- [ ] 2.1 `App/Sources/GuideLineRenderPath.swift`: mirror `GhostRenderPath` — inline
      MSL shader (mvp * position; solid amber fragment), `.line` primitive, positions
      only, no zero-copy; alpha blend; depth `.lessEqual` write-off. `GuideLineUniforms`
      + factory.
- [ ] 2.2 `ViewportRenderer`: `guideLinePath` property; `loadGuideLines(positions:
      indices:)` / `clearGuideLines()` (each `invalidate()`); encode after the wireframe
      overlay; add to the early-out guard; NOT in `isAnimating`.

## 3. Wire guides → overlay + Auto-Retopo

- [ ] 3.1 Coordinator `syncGuideLines`: flatten `authoredGuides` → shared positions +
      line-index pairs → `loadGuideLines`; called on `onGuidesChanged`.
- [ ] 3.2 `beginAutoRetopoAsync`: add `guideStrokes: authoredGuides.map { GuideStroke(
      points: $0) }` to the constraints. Empty ⇒ unchanged solve.

## 4. UI

- [ ] 4.1 An `EditorAction` / tool entry to arm Guide mode (gallery entry).
- [ ] 4.2 A Clear Guides control.

## 5. Tests (device + simulator)

- [ ] 5.1 Capture: a guide stroke over the Target yields a world polyline on the
      surface; a stroke missing the Target yields no guide; clear empties them.
- [ ] 5.2 `GuideLineRenderPathTests`: load/hasGeometry/clear; headless offscreen render
      shows amber pixels (`classifyAgainst`); no realloc on same-size reload.
- [ ] 5.3 Auto-Retopo threads authored guides into the solve; with none, unchanged.

## 6. Validation

- [ ] 6.1 `openspec validate add-guide-stroke-authoring --strict`.
- [ ] 6.2 Full suite green on simulator AND device.

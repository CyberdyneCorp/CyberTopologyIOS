# Tasks: add-uv-only-projects (6.1a)

## 0. Read the requirement before scoping
- [x] 0.1 Confirm the spec asks for a derived behaviour, not a document type. It does; the earlier
      task note was wrong.
- [x] 0.2 Confirm snapping is already disabled without a Target (`targetSnapper` is nil). It is.

## 1. UV-only projects
- [x] 1.1 `importUVOnlyProject(at:)` as a COMPOUND command (object + stage) = one undo.
- [x] 1.2 No compound when already in the UV stage, so no no-op stage step is journaled.
- [x] 1.3 `isUVOnlyProject` derived from the objects, never stored.
- [x] 1.4 An import entry point, carried as an INTENT rather than a second flag beside the role,
      so the two cannot desync.
- [x] 1.5 Tests: one undo restores both; adding a Target stops it being UV-only; unwrap, UDIM and
      export all work with no Target.

## 2. Split-view layout
- [x] 2.1 `UVSplitLayout`: pure state, gesture classification, transitions.
- [x] 2.2 Maximize by SIZING, never re-parenting.
- [x] 2.3 Gesture scoped to the 2D panel, not a container above the viewport.
- [x] 2.4 Divider line claimed only when a pane is maximized.
- [x] 2.5 An 18pt grab strip so no maximized state is a dead end.
- [x] 2.6 Tests, including that every state has a way out and that a diagonal resolves to nothing.

## 3. Close out
- [x] 3.1 validate; simulator (incl. UI tests), device.
- [x] 3.2 Master 6.1a entry, recording the scoping correction and the UI-test regression.

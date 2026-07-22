# Tasks: simplify-gesture-grammar

Ordered by dependency. Step 1 is a prerequisite for step 3 — re-tuning
against synthesized strokes has already failed twice.

## 1. Real-stroke corpus (prerequisite)

- [ ] 1.1 Capture 3-5 real failing quad strokes on device with the task-1.1b
      fixture recorder: adjacent-to-existing-quad, overshooting the seam,
      stopping short of the seam, on a curved surface. Commit under
      `CyberKit/Tests/CyberKitTests/Fixtures/Strokes/` with provenance
      (device, Target model, what the user intended).
- [ ] 1.2 Add a failing-by-design test asserting each records `createQuad`.
      It documents the bug before the fix, and becomes the acceptance
      criterion for task 3.

## 2. Cut the grammar to three gestures

- [ ] 2.1 Engine: restrict `interpretStroke`'s candidate set to
      `CreateQuad`, `CreateTriangle`, `DeleteFaces`. Leave `classifyShape`'s
      shape enum intact for now (the tools still use shapes) but stop
      emitting candidates for removed actions.
- [ ] 2.2 App: remove the removed actions from `ActionCatalog`'s GESTURE
      entries, keeping their TOOL entries. Gallery help text must stop
      describing them as gestures.
- [ ] 2.3 Interpretation chip: alternatives can only offer the three
      actions; the swap path (`performReplacingLast`) is unchanged.
- [ ] 2.4 Retire the gesture-level tests and goldens for removed actions;
      verify each capability still has TOOL-level coverage before deleting
      anything. Anything left uncovered gets a tool test in the same change.
- [ ] 2.5 Rewrite the `pencil-interaction` grammar scenarios in
      `tests/traceability.yaml`.

## 3. Re-tune closed-vs-open

- [ ] 3.1 Seam-tolerant self-intersection counting: crossings between
      leading and trailing segments do not disqualify a closed stroke.
      (Drafted in the unlanded patch 0023 — that half was sound.)
- [ ] 3.2 Nearly-closed rescue: an open stroke with quad-like corner
      structure classifies as a closed loop. With scribble and grid out of
      the grammar (task 2), the ordering conflict that broke this is gone
      and the threshold can be generous.
- [ ] 3.3 Drive both from the task-1.1 corpus, not synthesized strokes.
      Acceptance: every committed real quad stroke resolves to `createQuad`,
      and the X fixture still resolves to `deleteFaces`.
- [ ] 3.4 Run the FULL suite before claiming no regressions — the CyberKit
      recognizer suite alone missed an app-level break last time.

## 4. Weld created faces onto existing topology

- [ ] 4.1 Engine: corner-resolution pass for `createQuad`/`createTriangle` —
      a corner within a scale-free radius of an existing vertex reuses it; a
      corner on an existing edge shares that edge. Follow the Build Quad
      tool's release-merge semantics (task 4.1 of the parent change) rather
      than inventing new rules.
- [ ] 4.2 App: route the gesture path through it inside the stroke's single
      `MeshEditTransaction`, so one undo still removes the whole face.
- [ ] 4.3 Acceptance test from the reference application's counts: starting
      from one quad (4 v / 4 e / 1 f), drawing an adjacent quad sharing one
      edge yields 6 v / 7 e / 2 f — +2 vertices, +3 edges, +1 face, NOT +4
      vertices and a disconnected face.
- [ ] 4.4 Anti-vacuity: a quad drawn far from existing topology still
      creates 4 new vertices.

## 5. Deferred / explicitly out of scope

- Auto Relax after welded creation (task 4.5a of the parent change already
  tracks the missing create paths).
- Restoring any removed gesture as a MODIFIED gesture (e.g. delete-faces via
  a different stroke) — if the three-gesture set proves too small, that is a
  new proposal with its own device evidence.

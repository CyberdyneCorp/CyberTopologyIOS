# Tasks: simplify-gesture-grammar

Ordered by dependency. Step 1 is a prerequisite for step 3 — re-tuning
against synthesized strokes has already failed twice.

## 1. Real-stroke corpus (prerequisite)

- [x] 1.1 Capture 3-5 real failing quad strokes on device with the task-1.1b
      fixture recorder. Committed under
      `CyberKit/Tests/CyberKitTests/Fixtures/DeviceStrokes/` — NOT
      `Fixtures/Strokes/`, which is a synthetic corpus whose every file must
      match a code generator (`corpusMatchesGenerators`) and replay to its
      expected outcome; captured strokes satisfy neither. Four strokes, one
      per side of a central quad, each an open "U" adjacent to the shared
      edge; all recorded `shape=unknown; none:0.20` on device. Provenance
      (device, Target, intent, what the recognizer answered) is embedded in
      each fixture and summarized in `DeviceStrokes/PROVENANCE.md`.
      (Deferred: overshoot / stop-short / curved-surface variants — the four
      adjacent-quad captures already reproduce the bug; add the others if the
      re-tune needs more geometry.)
- [x] 1.2 `DeviceStrokeCorpusTests` asserts each capture resolves to
      `createQuad` through the real engine recognizer. Failing by design
      today, wrapped per-fixture in `withKnownIssue` so the suite stays green
      while the bug is documented; when the re-tune lands, each known issue
      resolves and Swift Testing flags it as unexpectedly passing. This is
      the acceptance criterion for task 3.

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
      (Drafted in the unlanded patch 0023 — that half was sound.) Deferred:
      the four device captures have zero self-intersections, so the rescue
      alone clears them; the overshoot variant that needs this is not yet in
      the corpus.
- [x] 3.2 Nearly-closed rescue: landed as engine patch
      `0023-stroke-nearly-closed-quad-rescue`. An open stroke that bounds a
      recoverable quad ring (no self-crossings, not straight, endpoints
      within `nearlyClosedFraction`=0.65 of the perimeter) classifies as a
      ClosedLoop. Placed LAST in `classifyShape`, so it only ever upgrades a
      would-be Unknown and cannot steal a grid/scribble/cross — which is why
      it works WITHOUT the task-2 grammar cut and breaks no synthetic
      fixture. Gated on geometry, not a corner-count threshold: two of the
      four device strokes are drawn smoothly and register < 2 sharp corners.
- [x] 3.3 Driven by the task-1.1 device corpus. `DeviceStrokeCorpusTests`
      now asserts (plainly, no longer `withKnownIssue`) that all four real
      quad strokes resolve to `createQuad`. The X fixture still resolves to
      `deleteFaces` (the rescue does not touch self-intersecting strokes).
- [x] 3.4 Full suite green: 560 app + 268 CyberKit, zero regressions.

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

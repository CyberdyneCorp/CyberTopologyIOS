# Tasks: add-weave-solver-pipeline

## 1. CyberKit: expose remesh progress + cancellation

- [ ] 1.1 Extend `Mesh.remeshed(...)` to accept `onProgress: ((SolverProgress) ->
      Void)?` and `isCancelled: () -> Bool`, forwarding them to the engine's
      `CyberProgressCb` / `CyberCancelCb` (currently passed NULL). A cancelled
      remesh returns nil having produced nothing; the input mesh is never mutated.
- [ ] 1.2 Keep the existing no-callback `remeshed()` working (defaults), so the
      current test and call sites are unaffected.

## 2. CyberKit: solver-session API + value types

- [ ] 2.1 Add `SolveRegion` (`wholeMesh`, `faces`), `WeaveConstraints` (all six
      constraint kinds), `SolverParameters` (wrapping `RemeshParameters` + seed),
      `SolverGhost` (mesh + addedFaces), `SolverProgress`. `Codable`/`Equatable`
      per the design.
- [ ] 2.2 Add the `WeaveSolving` protocol with the determinism, cancellation
      (returns nil, mutates nothing), and progress contracts documented on it.

## 3. CyberKit: EngineRemeshSolver backend

- [ ] 3.1 `EngineRemeshSolver: WeaveSolving`: solves `.wholeMesh` by running
      `Mesh.remeshed(...)` on the target with `params.remesh`, forwarding progress
      and cancel; returns the fresh quad mesh as the ghost (`addedFaces` = all
      faces). Field constraints are accepted and ignored for now.
- [ ] 3.2 Reject or no-op a `.faces` sub-region cleanly (unsupported this slice)
      with a clear error, so callers can rely on `.wholeMesh`.

## 4. App: Auto-Retopologize action + solver session

- [ ] 4.1 An `autoRetopo` `EditorAction` in the roster (batch panel / Action
      Gallery), arming through the arbiter.
- [ ] 4.2 A solver session on `MeshEditController` mirroring the camera-tool
      session shape: run the injected `WeaveSolving` over the Target, hold the
      `SolverGhost`, surface progress, allow cancel.
- [ ] 4.3 Render the ghost with the amber Weave `GhostStyle` via `GhostRenderPath`
      (distinct from the subdivision preview and hover hint).

## 5. Accept / override flow

- [ ] 5.1 Tap accepts: commit the ghost as the EditMesh (create-or-replace) in
      exactly ONE journal entry; accepted topology is ordinary EditMesh.
- [ ] 5.2 Draw-over or cancel discards the ghost leaving the document
      byte-unchanged (no journal entry).
- [ ] 5.3 Strict opt-in: with Auto-Retopo never invoked, no solver geometry is
      produced or rendered.

## 6. Tests (device + simulator, per the Phase 4 pattern)

- [ ] 6.1 Remesh progress/cancel: progress fractions are reported; a cancel
      partway returns nil and leaves the input mesh bit-identical.
- [ ] 6.2 Determinism (VERIFY, per design D4): two solves of the same target with
      the same params produce bit-identical ghost payloads. If it fails, file the
      engine issue and mark the requirement pending; do not weaken the spec.
- [ ] 6.3 `EngineRemeshSolver` produces quads over a real target (bunny/plane) and
      returns them as the ghost without mutating the source.
- [ ] 6.4 App-hosted ghost flow: accept journals exactly once and undo restores the
      exact bytes; draw-over discards; opt-in produces nothing; accepted topology
      accepts a follow-up verb (e.g. Relax) with no special-casing.
- [ ] 6.5 Share the CyberKit-level suites into the app-hosted target so they run on
      device too.

## 7. Validation

- [ ] 7.1 `openspec validate add-weave-solver-pipeline --strict`.
- [ ] 7.2 Full suite green on the simulator AND the iPad; `CyberKitTests` unaffected.

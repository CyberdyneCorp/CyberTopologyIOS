# Tasks: add-weave-solver-pipeline

## 1. CyberKit: expose remesh progress + cancellation

- [x] 1.1 Extend `Mesh.remeshed(...)` to accept `onProgress` and `isCancelled`,
      forwarding them to the engine's `CyberProgressCb` / `CyberCancelCb`
      (previously NULL). A cancelled remesh returns nil; the input is never mutated.
- [x] 1.2 Keep the existing no-callback `remeshed()` working (non-optional overload).

## 2. CyberKit: solver-session API + value types

- [x] 2.1 `SolveRegion`, `WeaveConstraints` (all six constraint kinds),
      `SolverParameters`, `SolverGhost`, `SolverProgress`.
- [x] 2.2 The `WeaveSolving` protocol with determinism / cancellation / progress
      contracts documented.

## 3. CyberKit: EngineRemeshSolver backend

- [x] 3.1 `EngineRemeshSolver: WeaveSolving` solves `.wholeMesh` via
      `Mesh.remeshed`, forwarding progress + cancel; ghost `addedFaces` = all faces.
- [x] 3.2 A `.faces` sub-region throws `invalidArgument` (unsupported this slice).

## 4. App: Auto-Retopologize action + solver session

- [x] 4.2 The solver session on the coordinator (begin/accept/discard) running the
      injected `WeaveSolving` over the Target and holding the `SolverGhost`.
- [ ] 4.1 An `autoRetopo` action in the toolbar / Action Gallery. DEFERRED (UI
      wiring): the session API exists; the button that calls `beginAutoRetopo` is
      the visual follow-up.
- [ ] 4.3 Render the ghost with the amber Weave `GhostStyle` via `GhostRenderPath`.
      DEFERRED (visual, mirrors the subdivision-preview ghost path; not unit-tested).

## 5. Accept / override flow

- [x] 5.1 `acceptAutoRetopo` commits the ghost as the EditMesh (create-or-replace)
      in exactly ONE journal entry; accepted topology is ordinary EditMesh.
- [x] 5.2 `discardAutoRetopo` drops the ghost with no journal entry.
- [x] 5.3 Strict opt-in: without a begin, no ghost or geometry exists.
- [ ] 5.x Gesture routing (tap → accept, draw-over → discard) through the arbiter.
      DEFERRED (UI wiring): the accept/discard methods exist and are tested; the
      gesture bindings are the visual follow-up.

## 6. Tests (device + simulator, per the Phase 4 pattern)

- [x] 6.1 Remesh progress bridges without crash; cancel returns nil and leaves the
      input bit-identical (`WeaveSolverTests`).
- [x] 6.2 Determinism VERIFIED: two solves → identical payloads. `cyber_remesh` is
      bit-deterministic — no engine issue needed.
- [x] 6.3 `EngineRemeshSolver` produces a quad ghost without mutating the source.
- [x] 6.4 App-hosted `AutoRetopoSessionTests`: accept journals once + undo restores;
      discard changes nothing; opt-in produces nothing; replace-existing is one step.
- [x] 6.5 `WeaveSolverTests` shared into the app-hosted target (runs on device too).

## 7. Validation

- [x] 7.1 `openspec validate add-weave-solver-pipeline --strict`.
- [ ] 7.2 Full suite green on the simulator AND the iPad; `CyberKitTests` unaffected.

## Deferred to a follow-up (UI wiring, noted above)

The interactive surface — the toolbar/Gallery Auto-Retopo button, the amber ghost
rendered through `GhostRenderPath`, and the tap-accept / draw-over-discard gesture
bindings — is the remaining visual layer. It mirrors the existing subdivision-preview
ghost path and is not unit-testable, so it is split out; the solver, the session state
machine, and every spec guarantee are implemented and tested here.

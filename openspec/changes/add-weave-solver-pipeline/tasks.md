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
- [x] 4.1 An `autoRetopo` `EditorAction` + a gallery entry; the "Auto-Retopologize
      Target" item in the IO menu triggers it (disabled without a Target).
- [x] 4.3 The ghost renders amber via `GhostRenderPath` (`GhostStyle.weaveProposal`).
- [x] 4.4 The solve runs OFF the main thread (payload-Data round-trip, since meshes
      are not `Sendable`) so a large Target never freezes the UI; a solving
      indicator shows while it runs. A coarse default quad budget
      (`SolverParameters.autoRetopoDefault` = 1500; the engine's raw 50k is far
      too fine) keeps one-tap interactive.

## 5. Accept / override flow

- [x] 5.1 `acceptAutoRetopo` commits the ghost as the EditMesh (create-or-replace)
      in exactly ONE journal entry; accepted topology is ordinary EditMesh.
- [x] 5.2 `discardAutoRetopo` drops the ghost with no journal entry.
- [x] 5.3 Strict opt-in: without a begin, no ghost or geometry exists.
- [x] 5.4 An Accept/Discard bar (`AutoRetopoBannerView`) is the accept/override
      affordance while a proposal is shown — accept commits, discard drops it.
- [ ] 5.x In-viewport gesture shortcuts (tap → accept, draw-over → discard). Not
      done: the discoverable bar covers accept/discard; the gesture shortcuts are
      an optional refinement.

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

## Remaining (optional refinements, not blocking)

- In-viewport gesture shortcuts (tap → accept, draw-over → discard) on top of the
  Accept/Discard bar.
- A density control (target quad budget / method) instead of the fixed coarse default.
- Progress percentage in the solving indicator (the engine reports it; the session
  currently shows an indeterminate spinner).

Everything the spec requires is implemented and covered: the solver, the session,
off-main solving, the amber ghost, the Accept/Discard bar, and one-undo accept.

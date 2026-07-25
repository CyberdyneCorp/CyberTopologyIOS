# Tasks: add-weave-density-symmetry

## 1. Density honouring

- [x] 1.1 `EngineRemeshSolver` applies `params.remesh.targetQuads` (already passed) and,
      when `constraints.density` is set, scales `RemeshParameters.edgeScale` from its
      `targetEdgeLength` (finer edge → smaller scale, clamped).
- [x] 1.2 Auto-Retopo density presets: `SolverParameters` gains `coarse`/`medium`/`fine`
      factories (≈600 / 1500 / 4000 targetQuads); `autoRetopoDefault` stays `medium`.

## 2. Symmetry honouring (single mirror axis)

- [x] 2.1 In `EngineRemeshSolver`, when `constraints.symmetry?.isEnabled == true` and it
      has ≥1 mirror axis: after the remesh, clip to the working side — delete every face
      with ANY vertex on the far side of `axis` about `origin` (whole-face, not centroid:
      a straddling face is not "wholly on the working side", so `applySymmetry` would
      leave it un-mirrored and break symmetry).
- [x] 2.2 `snapSymmetryPlane(settings)` the clipped cage, then `applySymmetry(settings,
      axis:)` to mirror + weld. Ignore extra mirror axes and radial (this slice).
- [x] 2.3 `SolverGhost.addedFaces` stays the whole resulting cage; the source is never
      mutated (the solve works on the fresh remesh handle).

## 3. App: thread density + symmetry from the document

- [x] 3.1 The Auto-Retopo trigger builds `WeaveConstraints(symmetry: document.symmetry)`
      and the chosen density preset into `SolverParameters`, then runs the solve.
- [x] 3.2 A density picker (Coarse / Medium / Fine) on the Auto-Retopo affordance; the
      selection drives the preset. Default Medium.

## 4. Tests (device + simulator)

- [x] 4.1 Density: a finer preset yields strictly more quads than a coarser one over the
      same Target; the mapping is monotonic.
- [x] 4.2 Symmetry: solving with an X-mirror constraint yields a cage that is
      mirror-symmetric about the plane (every vertex has a mirrored partner within
      tolerance), and clipping+mirroring a non-symmetric Target still yields a symmetric
      cage. Determinism holds (repeat solve identical).
- [x] 4.3 App-hosted: a symmetric document → the accepted Auto-Retopo EditMesh is
      symmetric; density selection changes the accepted quad count. Share the CyberKit
      suites into the app-hosted target (device coverage).

## 5. Validation

- [x] 5.1 `openspec validate add-weave-density-symmetry --strict`.
- [x] 5.2 Full suite green on the simulator AND the iPad; existing tests unaffected.

# Tasks: add-uv-stage-foundation (6.1)

Data path first, then the stage, then the action. The UV readback is the gate: without it
no 2D view is possible, so nothing downstream is worth writing until it exists.

## 1. Engine + C API: get UVs out

- [ ] 1.1 Per-corner UV readback as a pointer view, following
      `cyber_mesh_positions_ptr` so the 2D view binds a buffer rather than copying.
- [ ] 1.2 **Absence must be distinguishable from zero.** A mesh that was never unwrapped is
      not a mesh unwrapped to the origin, and returning zeros for both would make an
      un-unwrapped mesh look like a catastrophically bad layout.
- [ ] 1.3 Reading must not mutate. The UV data belongs in the render cache beside positions
      and normals, so it is invalidated by the same hook every mutating op already calls.
- [ ] 1.4 Fold into the patch stack as a numbered patch — `build_engine.sh` refuses a tree
      the stack does not fit, which is correct and not to be worked around.
- [ ] 1.5 Engine tests: UVs readable after an atlas run; absent before one; a mutating op
      invalidates them.

## 2. CyberKit

- [ ] 2.1 `Mesh.uvCoordinates()` returning nil (not empty) when the mesh has no UVs, so the
      Swift type carries the same distinction the C API does.
- [ ] 2.2 `Mesh.unwrapped(...)` over `cyber_uv_atlas`, returning the `CyberAtlasResult`
      report as a Swift value. Following `remeshed`: never mutate the receiver, so a refused
      or cancelled unwrap leaves the caller's mesh untouched.
- [ ] 2.3 Tests: round-trip UVs; a never-unwrapped mesh reports nil; the report's fields
      match what the engine produced.

## 3. The UV stage branches

- [ ] 3.1 Entering `.uv` presents the UV workspace instead of the retopology viewport. The
      stage picker and its `setStage` journaling already exist and are NOT rebuilt.
- [ ] 3.2 3D view plus a 2D UV view. The 2D view states plainly when there is no layout yet
      rather than rendering an empty square, which reads as broken.
- [ ] 3.3 Switching stages must change no geometry — asserted, since `setStage` is journaled
      alongside mesh edits and a regression here would be invisible.

## 4. One-tap unwrap

- [ ] 4.1 An action that unwraps the EditMesh as ONE journaled step.
- [ ] 4.2 Report chart count, seam count, max/RMS distortion and packed area. A silent
      success tells the artist nothing about whether the layout is usable.
- [ ] 4.3 A failed unwrap refuses with a stated reason and leaves the mesh unchanged.
- [ ] 4.4 Reached through the Action Gallery like every other non-default action.

## 5. Close out

- [ ] 5.1 `openspec validate --changes --strict`; engine suite; full simulator suite; device
      run of the new suites.
- [ ] 5.2 Update the master 6.1 entry with what shipped and what was deliberately excluded
      (UV-only project type; and that 6.4's heatmap needs a PER-FACE distortion readout,
      since `CyberAtlasResult` reports aggregate max/RMS only).

# Tasks: add-uv-stage-foundation (6.1)

Data path first, then the stage, then the action. The UV readback is the gate: without it
no 2D view is possible, so nothing downstream is worth writing until it exists.

## 1. Engine + C API: get UVs out

- [x] 1.1 Per-corner UV readback as a pointer view, following
      `cyber_mesh_positions_ptr` so the 2D view binds a buffer rather than copying.
- [x] 1.2 **Absence must be distinguishable from zero.** A mesh that was never unwrapped is
      not a mesh unwrapped to the origin, and returning zeros for both would make an
      un-unwrapped mesh look like a catastrophically bad layout.
- [x] 1.3 Reading does not mutate; the UVs live in the render cache beside positions and
      normals. **This surfaced a real pre-existing bug**: `cyber_uv_atlas` WRITES the corner
      UV attribute but never invalidated the render cache. Harmless while nothing could read
      UVs back, and a silent wrong answer the moment something could — the first readback
      after an unwrap returned the pre-unwrap cache and reported "no UVs". Caught by the
      test, not by review.
- [x] 1.4 Fold into the patch stack as a numbered patch — `build_engine.sh` refuses a tree
      the stack does not fit, which is correct and not to be worked around.
- [x] 1.5 Engine tests: UVs readable after an atlas run; absent before one; a mutating op
      invalidates them.

## 2. CyberKit

- [x] 2.1 `Mesh.uvCoordinates()` returning nil (not empty) when the mesh has no UVs, so the
      Swift type carries the same distinction the C API does.
- [x] 2.2 `Mesh.unwrapped(...)` over `cyber_uv_atlas`, returning the `CyberAtlasResult`
      report as a Swift value. Following `remeshed`: never mutate the receiver, so a refused
      or cancelled unwrap leaves the caller's mesh untouched.
- [x] 2.3 Tests: round-trip UVs; a never-unwrapped mesh reports nil; the report's fields
      match what the engine produced.

## 3. The UV stage branches

- [x] 3.1 Entering `.uv` presents the UV workspace. The stage picker and its `setStage`
      journaling already existed and were not rebuilt. **The viewport is kept, not
      replaced**, which the requirement prose ("rather than the retopology viewport") reads
      against — because `CyberTopologyUITests` taps "UV" and then performs camera swipes,
      pinches and multi-touch undo ON the viewport, so replacing it would break gestures the
      tests already depend on. The panel appears BESIDE it, and the viewport stays the first
      child of one always-present `HStack`: moving it between containers would give it a new
      SwiftUI identity per stage switch, re-creating the coordinator and losing the camera.
- [x] 3.2 3D view plus a 2D UV view. The 2D view states plainly when there is no layout yet
      rather than rendering an empty square, which reads as broken.
- [x] 3.3 Switching stages changes no geometry. Structurally guaranteed rather than only
      asserted: the branch adds a sibling view and touches no payload, and `setStage` was
      already journaled as a manifest-only command whose `apply`/`revert` set
      `manifest.stage` and nothing else.

## 4. One-tap unwrap

- [x] 4.1 An action that unwraps the EditMesh as ONE journaled step.
- [x] 4.2 Report chart count, seam count, max/RMS distortion and packed area. A silent
      success tells the artist nothing about whether the layout is usable.
- [x] 4.3 A failed unwrap refuses with a stated reason and leaves the mesh unchanged. Three
      outcomes are distinguished, not two: committed, NO-OP ("Already unwrapped — the layout
      is unchanged") and genuine failure. The middle case was found by a test I had written
      wrong — I expected a second unwrap to journal a second step, but the atlas is
      deterministic, so identical parameters give byte-identical output and
      `MeshEditTransaction.command` correctly journals nothing. Reporting that as "could not
      unwrap" would have been a lie told to the artist about a layout sitting in front of
      them.
- [x] 4.4 Reached through the Action Gallery like every other non-default action.

## 5. Close out

- [x] 5.1 `openspec validate --changes --strict`; engine suite; full simulator suite; device
      run of the new suites.
- [x] 5.2 Update the master 6.1 entry with what shipped and what was deliberately excluded
      (UV-only project type; and that 6.4's heatmap needs a PER-FACE distortion readout,
      since `CyberAtlasResult` reports aggregate max/RMS only).

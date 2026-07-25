# Tasks: add-weave-guide-field-steering

## 1. Engine: cross-field constraint injection (patch 0003)

- [x] 1.1 `crossfield.hpp`: `CrossFieldConstraint {FaceId, Vec3 direction}`;
      `computeCrossField` gains an optional `std::vector<CrossFieldConstraint>`.
- [x] 1.2 `crossfield.cpp`: after the feature-edge seed loop, project each
      constraint's world dir into the face frame, seed `cos/sin(4α)`, set
      `constrained[c]=1` (held through the re-pin loop). Empty ⇒ identical.

## 2. Engine: thread guides to the field-aligned path

- [x] 2.1 `core/quadrangulate.hpp`: `OrientationGuides {points, dirs}` (world space).
- [x] 2.2 `field_quadrangulator.{hpp,cpp}`: guided ctor/factory; at solve time
      project each world guide onto the current mesh's nearest face → per-face
      constraints → `computeCrossField`. (World-space because the isotropic stage
      rebuilt topology; input face ids do not survive.)

## 3. C API

- [x] 3.1 `cyber_mesh_set_orientation_guides(mesh, points_xyz, dirs_xyz, count)`
      storing guides on the handle (declared + defined, mirrors tagged edges).
- [x] 3.2 `cyber_remesh` builds `OrientationGuides` from the handle, forces the
      field-aligned quadrangulator when guides are present, and captures them in
      the per-island factory lambda (pipeline.cpp untouched).
- [x] 3.3 `Engine/patches/0003-*.patch` generated (isolated from 0001/0002 via a
      temp base tree); full stack 0001→0002→0003 applies cleanly; engine rebuilt
      (limited parallelism, no OOM). build_engine.sh docs updated.

## 4. CyberKit

- [x] 4.1 `Mesh.setOrientationGuides(points:directions:)` wrapping the capi setter.
- [x] 4.2 `EngineRemeshSolver` maps `WeaveConstraints.guideStrokes` (world
      polylines) and `.taggedLoops` (source edges → endpoints) into
      `(midpoint, tangent)` samples, set on the source before the remesh.

## 5. Tests (device + simulator)

- [x] 5.1 A guide steers flow: a guide at 30° on a flat plane makes the output
      edges align to the guide direction more than an unguided solve (measured by
      mean 4-RoSy edge alignment).
- [x] 5.2 An empty guide set leaves the solve byte-identical.
- [x] 5.3 A guided solve is deterministic (repeat solve identical payload).
- [x] 5.4 Shared into the app-hosted target (runs on device too).

## 6. Validation

- [x] 6.1 `openspec validate add-weave-guide-field-steering --strict`.
- [x] 6.2 Full suite green on simulator (734) AND device; engine + CyberKit link.

## Deferred (named non-goals)

- **Guide-stroke authoring UI in Auto-Retopo** — the engine + API honour guides;
  an interactive gesture to draw them as a retopo input is a follow-on.
- **Tagged loops in whole-Target retopo** — they live on the EditMesh, which
  whole-Target retopo discards (the same source problem pins have); needs regional
  solve. The API path is in place for when a source is available.
- **Soft / weighted constraints**; steering the QuadCover/seamless-MIQ path.

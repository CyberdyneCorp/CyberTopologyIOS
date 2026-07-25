# Design: add-weave-guide-field-steering

## Context

The engine's field-aligned quadrangulator quad flow is a pure function of a 4-RoSy
cross field (`computeCrossField`). That field is seeded ONLY from geometric
feature/boundary edges, hard-pinned via `constrained[]`/`constraintDir[]` and held
through a transport-averaging relaxation. There is no channel for a caller to inject
an orientation. This change adds one, reusing the exact hard-pin mechanism.

## The four layers (all edited via `Engine/patches/0003`)

### 1. Cross field (`crossfield.{hpp,cpp}`)
`computeCrossField` gains an optional `std::vector<CrossFieldConstraint>` (`{FaceId,
Vec3 direction}`). After the feature-edge seeding loop, each constraint projects its
world direction into the target face's tangent frame (`frameAngle`, which is
inherently in-plane since the frame vectors are in-plane), seeds `cos/sin(4α)`, and
sets `constrained[c] = 1`. The re-pin loop already skips constrained faces, so the
guide is held exactly like a feature edge. Empty list ⇒ byte-identical to before.

### 2. Field-aligned quadrangulator (`field_quadrangulator.{hpp,cpp}`)
Holds an `OrientationGuides` (world-space `points`/`dirs`). At solve time it projects
each guide sample onto the CURRENT mesh's nearest live triangle (brute force — guide
samples are few) and passes the resulting per-face constraints to `computeCrossField`.

**Load-bearing gotcha (why guides are world-space, not face ids):** the isotropic
stage rebuilds island topology BEFORE the field solve, so input face ids do not
survive. Guides must be world geometry re-projected at solve time.

### 3. Seam (`core/quadrangulate.hpp`)
Defines `OrientationGuides` (world points + dirs). No `Parameters` change — that
struct stays scalar-only (its `validate()` contract).

### 4. C API (`capi.{h,cpp}`)
`cyber_mesh_set_orientation_guides(mesh, points_xyz, dirs_xyz, count)` stores guides on
the mesh handle (like `taggedEdges`, but read by remeshing not rendering). `cyber_remesh`
builds an `OrientationGuides` from the handle, and when non-empty forces the
field-aligned quadrangulator (the only path that consumes the cross field) and captures
the guides in the per-island factory lambda — so `pipeline.cpp` is untouched.

## Swift layers

- CyberKit `Mesh.setOrientationGuides(points:directions:)` wraps the capi setter.
- `EngineRemeshSolver` maps `WeaveConstraints.guideStrokes` (world polylines) and
  `.taggedLoops` (source edge ids → endpoints) into `(midpoint, tangent)` samples and
  sets them on the source before remeshing.

## Key decisions

### D1 — Hard pins first
Guides are hard-pinned (held through relaxation), reusing proven feature-edge
machinery with no new solver math. Soft/weighted constraints (a weighted row in the
spmv relaxation, better for controlled singularity placement) are a deferred follow-on.

### D2 — Determinism preserved
`computeCrossField` is deterministic and the guide projection (nearest-centroid) is a
pure function of the mesh + guides, so a guided solve stays bit-deterministic — tested.

### D3 — Field-aligned only
Only the field-aligned quadrangulator consumes `computeCrossField`; a guided remesh
forces it. Steering the QuadCover/seamless path (feeding guides into the MIQ solve) is
a larger, separate effort — out of scope.

### D4 — App scope: engine + CyberKit + API, not a guide-drawing UI
This change opens and proves the steering channel (engine + CyberKit + tests). Wiring
an interactive guide-stroke authoring UI into Auto-Retopo — and honouring tagged loops
that live on the EditMesh (which whole-Target retopo discards, the same source problem
pins have) — needs regional solve and a guide-authoring gesture, both deferred.

## Risks / Trade-offs

- **Steering strength / tuning** — hard pins bias strongly at guided faces and the
  field smooths between; singularity placement near guide endpoints is not tuned. The
  test asserts a measurable directional improvement, not optimal topology.
- **Nearest-centroid projection** — coarse but adequate for tens of samples; a
  closest-point-on-triangle or radius spread is a refinement.
- **First engine-submodule change** — delivered as patch 0003; the engine rebuild uses
  limited parallelism (`CMAKE_BUILD_PARALLEL_LEVEL=2`) to stay within memory.

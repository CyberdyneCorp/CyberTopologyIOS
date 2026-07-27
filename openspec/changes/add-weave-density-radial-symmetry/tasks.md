# Tasks: add-weave-density-radial-symmetry (5.2b)

Two independent halves. Neither blocks the other; both are engine work rather than app
wiring, which is why they were split out of 5.2a.

## 1. Density brush — the composition question first

- [x] 1.1 **DECIDED: multiply, then clamp to the same [0.3, 3.0] band**, written down at
      `IsotropicOptions::densityScales` before the code and asserted by test. Multiply
      because both terms are multipliers on the same quantity and because multiplication
      COMMUTES, which is what makes the result order-independent as the spec requires. NOT
      override: discarding curvature where the artist painted coarse throws away detail
      preservation they did not ask to lose. Same band rather than wider, because the
      split/collapse thresholds are tuned against it and a product reaching 9.0 risks the
      compounding runaway documented at `kScaleAttribute` (a 100x face-count explosion) —
      so an authored 3.0 over a curvature 3.0 yields 3.0, honoured up to the band and
      never past it.
- [x] 1.2 Engine (patch 0008): let the authored scale reach `kScaleAttribute` without
      `computeTargetScales` overwriting it — today it `std::fill`s the array to 1.0 first,
      which would erase anything authored.
- [x] 1.3 C API entry point carrying per-vertex scales, following the shape of
      `cyber_mesh_set_orientation_guides` (rides the handle, cleared after the solve).
- [x] 1.4 `DensityField` gains a per-vertex channel beside `targetEdgeLength`.
- [ ] 1.5 Brush UI — **NOT DONE, and deliberately last.** The whole channel below it is
      live and tested (engine composition, C API, `DensityField.perVertex`,
      `Mesh.setDensityScales`), so what remains is an authoring surface: paint scales onto
      the EditMesh, journaled as annotation state so it persists and undoes like pins and
      frozen faces. Left open rather than rushed because it needs a real interaction
      decision — brush radius and falloff, how the painted field is VISUALISED (a field
      the artist cannot see is a field they cannot correct), and whether it belongs on the
      EditMesh or the Target. Shipping a channel with no UI is the honest half: nothing
      claims the brush is usable yet.
- [x] 1.6 Tests: finer yields MORE faces and coarser yields FEWER (both directions — a
      single-direction test would not catch an inverted sign convention); an authored 10x
      behaves exactly like 3x, which is the clamp rule being asserted rather than assumed;
      all-1.0 is inert; a SHORT array is honoured where it applies and reads 1.0 past its
      end. Plus, caught by test rather than review: `DensityField`'s SYNTHESIZED `Codable`
      treated `perVertex` as required and threw `keyNotFound` on every pre-5.2b document —
      fixed with the explicit `decodeIfPresent` pattern `MeshAnnotations` and
      `SymmetrySettings` already use for exactly this hazard.

## 2. Radial symmetry in the solver

- [x] 2.1 Sector clip: faces wholly inside `[0, 2pi/N)` about `radialAxis`. Vertices lying
      ON the axis have no meaningful angle and belong to every sector, so they are never
      clipped — otherwise the solve would delete the centre of its own cage.
- [x] 2.2 Replicate the sector `radialCount` times and weld the rotational seams through
      `rotationalWeld`, which already exists for the bake path.
- [x] 2.3 Composed: the working domain is the INTERSECTION of orthant and sector, and
      radial runs BEFORE mirroring. Order matters and is fixed deliberately — rotation and
      reflection do not commute, and mirroring first would build a full symmetric mesh that
      the sector clip then mostly discards.
- [x] 2.4 Tests: the result is invariant under rotation by 360/N; no unwelded duplicates on
      a sector boundary; **radialCount == 1 is byte-identical to radial disabled**.

## 3. Close out

- [x] 3.1 `openspec validate --changes --strict`; full simulator suite; engine suite.
- [x] 3.2 Update the master 5.2a entry to record that its task 5.3 split landed here, and
      say which of the six constraint kinds are honoured end to end once this closes.

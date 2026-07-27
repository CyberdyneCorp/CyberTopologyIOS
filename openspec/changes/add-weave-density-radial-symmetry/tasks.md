# Tasks: add-weave-density-radial-symmetry (5.2b)

Two independent halves. Neither blocks the other; both are engine work rather than app
wiring, which is why they were split out of 5.2a.

## 1. Density brush — the composition question first

- [ ] 1.1 Decide and DOCUMENT how an authored per-vertex scale composes with the
      curvature-derived one `computeTargetScales` writes. Multiply is the obvious default,
      but an authored coarse scale over high curvature has to resolve somehow, and picking
      it silently is how the field becomes unpredictable. Write the rule down before the
      code.
- [ ] 1.2 Engine (patch 0008): let the authored scale reach `kScaleAttribute` without
      `computeTargetScales` overwriting it — today it `std::fill`s the array to 1.0 first,
      which would erase anything authored.
- [ ] 1.3 C API entry point carrying per-vertex scales, following the shape of
      `cyber_mesh_set_orientation_guides` (rides the handle, cleared after the solve).
- [ ] 1.4 `DensityField` gains a per-vertex channel beside `targetEdgeLength`.
- [ ] 1.5 Brush UI: paint density onto the EditMesh, journaled as annotation state so it
      persists and undoes like pins and frozen faces.
- [ ] 1.6 Tests: a finer region yields a smaller mean edge length; **no authored density is
      byte-identical to before** (the inertness property that keeps this from changing
      existing output by existing); composition follows the documented rule and is
      order-independent.

## 2. Radial symmetry in the solver

- [ ] 2.1 Sector clip: keep faces wholly inside one angular wedge about `radialAxis`.
      NOT an intersection of half-spaces — that is what multi-axis mirror needed, and
      reusing it here would silently produce a non-symmetric mesh.
- [ ] 2.2 Replicate the sector `radialCount` times and weld the rotational seams through
      `rotationalWeld`, which already exists for the bake path.
- [ ] 2.3 Compose with mirror symmetry when both are enabled, and fix an order.
- [ ] 2.4 Tests: the result is invariant under rotation by 360/N; no unwelded duplicates on
      a sector boundary; **radialCount == 1 is byte-identical to radial disabled**.

## 3. Close out

- [ ] 3.1 `openspec validate --changes --strict`; full simulator suite; engine suite.
- [ ] 3.2 Update the master 5.2a entry to record that its task 5.3 split landed here, and
      say which of the six constraint kinds are honoured end to end once this closes.

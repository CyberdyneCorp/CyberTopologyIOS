# Tasks: add-stage-dependent-x-gesture (6.2b)

## 0. Prove the defect first
- [x] 0.1 A failing test showing an X in the UV stage currently DELETES faces. Written before
      the fix so the regression test is known to bite.

## 1. Engine
- [x] 1.1 C API to unwrap the island containing a given face, honouring the authored seam set
      for the island partition.
- [x] 1.2 The new parameterization is fitted UNIFORMLY into the island's previous footprint and
      centred (an exact box fill would shear away the conformality just solved for). The
      primitive REFUSES a mesh with no UVs rather than creating a column that leaves every
      other island collapsed at the origin.
- [x] 1.3 Render-cache invalidation (the 6.1 bug: mutating UVs without invalidating is a
      silent wrong answer now that something can read them).
- [x] 1.4 Patch-stack entry.
- [x] 1.5 Tests: other islands' UVs are bitwise unchanged; the re-unwrapped island stays in
      its box; repeating the unwrap is stable; a face in no island is rejected.

## 2. CyberKit
- [x] 2.1 `Mesh.unwrapIsland(containing:)`.
- [x] 2.2 Tests: island isolation, and absence-vs-zero for a never-unwrapped mesh.

## 3. App
- [x] 3.1 `MeshEditController.Context` carries the document stage.
- [x] 3.2 `.cross` routes by stage: RT deletes, UV re-unwraps. One journaled step either way.
- [x] 3.2a UV-stage policy: no UVs yet runs the WHOLE-mesh unwrap; UVs present re-unwraps the
      one island. Test that no island is left collapsed at the origin either way.
- [x] 3.3 The interpretation chip says what actually happened, per stage.
- [x] 3.4 Regression test from 0.1 now passes.

## 4. Close out
- [x] 4.1 validate; engine, simulator, device.
- [x] 4.2 Master 6.2b entry, including the corner-pinning scope correction and the fact that
      the old behaviour was destructive rather than absent.

## 5. Discovered during implementation
- [x] 5.1 The regression test from 0.1 needed WEAKENING, not strengthening. Its first form
      asserted the payload was untouched, which is wrong: the fixture had never been unwrapped,
      so the X correctly runs the whole-mesh unwrap and the payload legitimately grows from 265
      to 754 bytes (the `vt` lines). Asserting "untouched" would have been asserting the
      gesture did nothing. It now pins what actually matters — geometry preserved, no delete
      journaled, and UVs present afterwards.
- [x] 5.2 The alternative-swap path needed the same gate as the apply path. Without it the
      interpretation chip would offer "Delete faces" as a one-tap alternative in a stage where
      an X does not delete — a second route to the destructive behaviour. Both now consult one
      `crossMeaning` switch.
- [x] 5.3 `crossMeaning` had to be `nonisolated`: it is a pure function of the stage, but as a
      static on a `@MainActor` class the chip builder (not main-actor isolated) could not call
      it, and the tempting fix was a second copy of the rule in the chip.
- [x] 5.4 The seam-source choice ("authored if any, else autoSeams") is now ONE C API helper
      shared by `cyber_uv_atlas` and the re-unwrap. Two copies could drift, and a drifted copy
      means the island re-unwrapped is not the one the artist pointed at.

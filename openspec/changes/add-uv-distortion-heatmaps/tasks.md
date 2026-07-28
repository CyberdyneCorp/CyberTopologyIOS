# Tasks: add-uv-distortion-heatmaps (6.4)

Cheaper than 6.1's scoping implied: the per-face computation already exists and is tested
engine-side, so this is an exposure plus a fill.

## 1. C API

- [x] 1.1 Per-face distortion readback over the same live-face order `liveFaceIDs()` walks,
      so the app can index it against the rings it already reconstructs. Reuses
      `cyber::uv::measureDistortion` — do NOT recompute distortion, or the panel and the
      atlas report become two sources of truth for the same question.
- [x] 1.2 Absence reported as absence, matching `cyber_mesh_uvs_ptr`: a mesh with no layout
      has no distortion, which is not the same as zero distortion.
- [x] 1.3 Fold into the patch stack as a numbered patch.
- [x] 1.4 Engine test: readable after an atlas run, absent before one (with a POISONED
      out-count, to catch a callee that forgets to write it), one entry per live face, every
      value finite and in range, and the worst per-face angle within the atlas's own
      aggregate — which is what proves the two are one measurement rather than two. The
      flipped case is covered engine-side already by `tests/uv/test_uv.cpp`, so it is not
      duplicated here; the app-side colour mapping asserts flipped shading directly.

## 2. CyberKit

- [x] 2.1 `Mesh.uvDistortion()` returning nil when there is no layout.
- [x] 2.2 Texel density derived from the area ratio, taking the texture size as a PARAMETER
      rather than baking one in — the figure is meaningless without the size it is
      expressed against.
- [x] 2.3 Tests: nil before an unwrap; one entry per face after; density scales with the
      square of the texture size.

## 3. The panel shades by distortion

- [x] 3.1 Fill each ring by its measurement, keeping the existing stroke so face boundaries
      stay legible over a fill.
- [x] 3.2 A mode switch between angle distortion and texel density, with the texture size
      stated for density.
- [x] 3.3 Flipped faces called out distinctly, not merely shaded — a flipped face is a defect,
      not a point on a scale.
- [x] 3.4 Pure colour-mapping functions, testable without a view.

## 4. Close out

- [x] 4.1 `openspec validate --changes --strict`; engine suite; simulator suite; device run.
- [x] 4.2 Update the master 6.4 entry, and correct 6.1's claim that the per-face readout did
      not exist.

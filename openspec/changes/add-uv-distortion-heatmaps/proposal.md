# UV distortion and texel-density heatmaps (6.4)

## Why

A UV layout's numbers say whether it is bad; a heatmap says WHERE. `AtlasReport` already
gives max and RMS angle distortion across the whole atlas, which is enough to know a layout
is poor and useless for fixing it — the artist needs to see which faces are stretched.

## Correcting the record first

When scoping 6.1 I wrote that 6.4 "needs a per-face distortion readout that does not
exist" and called it "a second engine change, not a shader". **The first half was wrong.**
`cyber::uv::measureDistortion` (src/uv/include/cyber/uv/distortion.hpp) already computes,
per face:

- `angle` — conformal error in [0, 1), the map Jacobian's |s1−s2|/(s1+s2) averaged over the
  face's fan triangles. 0 is angle-preserving.
- `area` — the ratio |uvArea| / surfaceArea, unnormalised. 0 for a collapsed face.
- `flipped` — true when the face's UV winding is reversed.

It is header-only, already used by `atlas.cpp` to produce the aggregate figures, and
already covered by `tests/uv/test_uv.cpp`. So the computation is done and tested; what is
missing is only the C API exposure. That makes 6.4 considerably cheaper than I implied, and
the estimate should not stand uncorrected.

**Texel density is derivable from the same data.** `FaceDistortion.area` is UV area over
surface area, so texels per unit surface at a given texture size is `area × textureSize²`.
No second engine computation is needed — which also means the per-face density and the
atlas's aggregate `texelDensity` cannot drift apart, because they come from the same source.

## What changes

**C API:** a per-face distortion readback following the pointer-view pattern, over the same
live-face order `liveFaceIDs()` walks so the app can index it against the rings it already
reconstructs. Absent UVs must report absence, matching `cyber_mesh_uvs_ptr` — a mesh with no
layout has no distortion, which is different from having zero distortion.

**CyberKit:** `Mesh.uvDistortion()` returning nil when there is no layout, and a per-face
texel-density derivation that takes the texture size as its unit rather than baking one in.

**App:** the 2D panel fills each face ring by distortion instead of only stroking it, with a
mode switch between angle distortion and texel density. Flipped faces are called out
distinctly, since a flipped face is a defect rather than a point on a scale.

## Non-goals

- **A 3D-surface heatmap.** The same per-face data could tint the 3D view, but that means a
  new per-face colour channel in the Target/overlay passes; the 2D panel is where an artist
  judges a layout, and it needs no new render path.
- **Choosing the colour ramp by measurement.** A ramp is a presentation decision, not a
  correctness one. It gets a defensible default and no more.
- **Per-chart statistics in the panel.** `AtlasReport` already reports the aggregate, and a
  second summary computed from the rings would be a competing source of truth.

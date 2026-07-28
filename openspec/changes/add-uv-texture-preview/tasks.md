# Tasks: add-uv-texture-preview (6.3c)

## 0. Confirm the gap is real
- [x] 0.1 Verify no shader in the app samples a texture, and no render path carries UVs. Both true.

## 1. Geometry
- [x] 1.1 `UVCheckerGeometry`: corner-expanded, non-indexed vertices (position, normal, uv).
- [x] 1.2 nil for a never-unwrapped mesh, keeping absence distinguishable from an empty preview.
- [x] 1.3 Reject mismatched streams and out-of-range indices rather than building a partial mesh.
- [x] 1.4 Tests, including that two corners of the same vertex keep DIFFERENT UVs (the seam case a
      vertex-indexed stream could not represent).

## 2. Render path
- [x] 2.1 Pipeline, depth state (writes ON — opaque surface), pooled buffer upload.
- [x] 2.2 Procedural checker in the fragment shader, two greys, wrap shading.
- [x] 2.3 Clamped uniforms so a bad density or opacity cannot blank the preview.
- [x] 2.4 Settings on the renderer, so density is adjustable and tests can disable shading.

## 3. Integration
- [x] 3.1 Encoded BEFORE the line overlays, so the wireframe and annotations sit on top.
- [x] 3.2 Gated to the UV stage; cleared with no layout; re-synced on a stage switch.

## 4. Tests
- [x] 4.1 Offscreen render asserting the image depends on UV and on density.
- [x] 4.2 Mutation-verified against BOTH a single-tone shader and a UV-independent one — the first
      two versions of this test caught neither.

## 5. Close out
- [x] 5.1 validate; simulator, device.
- [x] 5.2 Master 6.3c entry, recording the three test attempts and what remains (imported image,
      UV2D per-vertex mode).

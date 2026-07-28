# Checker texture preview on the 3D surface (6.3c)

## Why

A UV layout is judged by what it does to a texture. The 2D panel shows the layout and 6.4's heatmaps
quantify distortion, but neither shows what an artist actually looks for: whether the squares on the
model are square.

This is also what 6.3b's "live texture feedback" was specified against, and the reason that half was
split out — nothing in the app sampled a texture.

## The first textured render path, and why it needed building

Verified rather than assumed: the app's only Metal is inline shader strings in `GhostRenderPath` and
`GuideLineRenderPath`, neither samples a texture, and **neither the Target nor the overlay vertex
stream carries UVs at all**. So this is a new path — modelled on `GuideLineRenderPath` (runtime
shader compile, pooled buffers, depth-tested) with a UV attribute added.

## Corner-expanded, non-indexed — by necessity

UVs are a per-CORNER attribute because a seam gives one vertex several different UVs. A
vertex-indexed stream would have to pick one UV per vertex and would **weld every seam shut** — the
exact trap `cyber_mesh_uvs_ptr` was designed per-corner to avoid. So the preview expands to a
non-indexed triangle list, three unique vertices per triangle, and pays a little memory to keep the
seams the artist authored.

Mismatched streams build NOTHING rather than a partial mesh: a preview assembled from a UV stream and
an index stream that disagree would texture the model with plausible-looking nonsense.

## Procedural, not a sampled image

The checker is generated in the fragment shader from UV. No asset, no texture upload, no sampler
state — and it is exactly what the preview is for. An IMPORTED image would additionally need asset
loading and a real texture while visualizing nothing a checker does not, so it is a separate concern
rather than a prerequisite (recorded as still open).

Two greys rather than saturated colours, so the checker reads as a texture the model is WEARING
rather than as a highlight competing with the distortion heatmap. Depth writes are ON, unlike the
line overlays: this is opaque surface shading, so a nearer triangle must occlude a farther one.

## The offscreen test took three attempts, and mutation testing is why

Worth recording, because two versions of this test passed against a deliberately broken shader:

1. **"At least two tone bands."** Passed with a SINGLE-colour shader — wrap shading varies brightness
   across every face, which alone produced several bands.
2. **"The two dominant tones differ substantially."** Also passed with a single-colour shader, and
   with one ignoring UV entirely — the dominant tones were coming from the **Target pass underneath**,
   not from the checker at all.
3. **"The image depends on UV and on density."** Loading the checker must change the image, and
   changing only the density must change it again. A single-tone shader renders identically at every
   density; so does one ignoring UV. Both mutations now fail.

The renderer's checker settings are exposed partly so the test can switch wrap shading OFF, removing
the confound that made attempt 1 vacuous.

## Gated to the UV stage

A checker over the cage during retopology would hide the topology being authored, and the preview
answers a UV-stage question. It also clears when the mesh has no layout, so an un-unwrapped cage shows
its wireframe rather than an untextured surface pretending to be a preview. A stage switch re-syncs
it, because a stage change moves no payload and would otherwise leave the preview until the next edit.

## Out of scope

- **Imported-image preview** (above): needs asset loading and a real texture.
- **Per-vertex mode in UV2D**, the last fragment of 6.3's original text.

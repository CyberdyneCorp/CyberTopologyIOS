# UV stage foundation: make the stage real, and get UVs out of the engine (6.1)

## Why

Phase 6's entry point. Scoped as a VERTICAL SLICE rather than breadth-first, so the stage
does something end to end before the larger UV features (seam authoring, on-surface
manipulation, packing) are built on top of it.

## What exists, measured rather than assumed

Reading the code first changed what this change has to be:

- **`DocumentManifest.Stage` already has `.uv`.** The stage picker exists in
  `DocumentEditorView`, and switching stages journals a `setStage` command.
- **But NOTHING branches on `.uv`.** Switching to the UV stage today stores the stage and
  shows the retopology viewport unchanged. The switcher is real; the stage is empty.
- **The engine can unwrap.** `cyber_uv_atlas` seams into normal-coherent charts, LSCM-
  unwraps each, packs them into the unit square and writes per-corner UVs IN PLACE.
  `CyberAtlasParams` exposes chart angle, pack margin, texture size, chart reorientation and
  two merge controls; `CyberAtlasResult` reports chart count, seam edges, max and RMS
  angle distortion, flipped and fallback charts, packed area and texel density.
- **But UVs cannot be READ back.** There is no `cyber_mesh_uv_ptr`, no UV field in the
  render cache, and no attribute accessor. The atlas writes UVs the OBJ exporter can emit
  and nothing else can see.

That last point is the load-bearing discovery: **a 2D UV view is impossible today**, no
matter how the UI is written, because the data cannot leave the engine. Every remaining
Phase 6 task depends on it.

## What changes

**Engine + C API:** a per-corner UV readback, following the established pointer-view
pattern (`cyber_mesh_positions_ptr` and friends) so the 2D view binds a buffer directly
rather than copying. Absent UVs must be distinguishable from degenerate ones — a mesh that
has never been unwrapped is not a mesh unwrapped to zero.

**The UV stage branches.** Entering `.uv` shows the UV workspace instead of the retopology
viewport: the 3D view plus a 2D UV view, with the unwrap action and its quality readout.

**One-tap unwrap.** The auto-atlas behind a single action, journaled as one undoable step,
reporting what it produced from `CyberAtlasResult` rather than silently succeeding — chart
count, seam count, distortion and packed area are exactly what tells an artist whether the
result is usable.

## Non-goals, each with a reason

- **Seam authoring (6.2).** The engine auto-seams; there is no API to SUPPLY seams and no
  corner pinning. That is a separate engine surface, and building the stage first gives it
  somewhere to live.
- **Distortion heatmaps (6.4).** `CyberAtlasResult` reports AGGREGATE distortion (max and
  RMS across charts), not per-face. A heatmap needs a per-face readout that does not exist,
  so 6.4 is a second engine change, not a shader.
- **On-surface UV manipulation (6.3), Metal packing (6.6), UV sets and UDIM (6.7).** Each
  needs API the engine does not expose; 6.7 additionally needs a document-model change,
  since the atlas writes ONE UV set into the unit square.
- **UV-only project type.** Part of 6.1's text, but it is a document-model and
  document-browser change with its own import path, and bundling it here would double the
  change for no gain in the slice.

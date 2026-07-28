# add-uv-distortion-heatmaps

Phase 6's 6.4. `AtlasReport` already says a layout is distorted; a heatmap says WHERE. Cheaper than 6.1's scoping claimed — and that claim is corrected here: `cyber::uv::measureDistortion` already computes per-face angle error, UV-to-surface area ratio and flipped winding, is used by `atlas.cpp` for the aggregate figures, and is already tested. So this is a C API exposure plus a fill in the existing Canvas, not new engine maths. Texel density derives from the same area ratio, which also stops the per-face and aggregate figures from drifting apart.

# add-uv-imported-preview

Phase 6's 6.3d, the last of it: an imported-image UV preview sampled on the 3D surface, and per-vertex editing in the 2D view. A "UV vertex" is a CLUSTER of coincident corners, which is what keeps a per-vertex drag from tearing an island — and preserves seams with no seam-specific logic at all.

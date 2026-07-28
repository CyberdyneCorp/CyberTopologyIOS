# add-uv-island-editing

Phase 6's 6.3, first slice: the island-editing DATA layer (transform, grid straighten, partial symmetry, clone, stitch) plus the 2D island grammar in the UV panel — stroke on the upper third rotates, lower third scales, middle moves. Every engine primitive already existed; "relax with corner auto-pinning" turned out to be `reunwrapIsland`, already shipped in 6.2b. The UV3D on-surface pinch is split out as 6.3b because it needs input arbitration against the camera pinch, not because of its size.

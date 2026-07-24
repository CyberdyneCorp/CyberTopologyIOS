# Mesh test fixtures — provenance

Synthetic fixtures (`cube.obj`, `cube_colored.obj`, `grid32.obj`) are authored
by hand for the unit suites and documented at their point of use.

Real scanned Targets, used by `RealTargetIntegrationTests` to exercise the OBJ
loader, the `SurfaceSnapper` BVH and reprojection on dense, genuinely-curved,
irregular triangle geometry (as opposed to the flat planes / analytic domes the
per-tool suites use):

- `stanford-bunny.obj` — the Stanford Bunny (Stanford 3D Scanning Repository),
  35,947 vertices / 69,451 triangles.
- `armadillo.obj` — the Armadillo (Stanford 3D Scanning Repository), 49,990
  vertices / 99,976 triangles.

Both are classic, freely-available reference scans. They are checked in so the
real-target integration tests are repeatable on any machine and on device.

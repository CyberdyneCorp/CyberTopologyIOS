# Mesh fixture provenance

Committed mesh fixtures, pinned so the corpus can never silently drift
(same convention as the stroke corpus in `StrokeGestureCorpus`).

## bunny.obj

| | |
|---|---|
| Source | <https://graphics.stanford.edu/~mdfisher/Data/Meshes/bunny.obj> |
| Retrieved | 2026-07-22 |
| SHA-256 | `e4bfe098950c61c42190fefe8f23ad7b469da8d5d488c8f8e28a0e0b00c4c88c` |
| Size | 205 917 bytes |
| Contents | 2503 vertices, 4968 triangles, no normals, no vertex colours, no MTL |

The Stanford bunny, from the Stanford Computer Graphics Laboratory's 3D
Scanning Repository (Turk & Levoy, 1994), by way of the decimated OBJ
repackaging above. The Stanford repository asks that the source be
acknowledged in work that uses the models; this file is test data only and
is never shipped in the app bundle.

Why this mesh, and why committed rather than generated: the existing OBJ
fixtures (`cube.obj`, `grid32.obj`) are 8–32 faces of hand-written,
perfectly regular topology. They cannot exercise the things a real import
has to survive — thousands of faces, irregular valence, a non-trivial
bounding box far from the unit cube, and float coordinates in scientific
notation. The bunny is the smallest widely-recognised mesh that does, at
200 KB it is cheap to commit, and pinning the hash means an import
regression can never be explained away as "the fixture changed".

The SHA-256 above is asserted by `MeshFixtureCorpusTests`, so replacing the
file without updating this table fails the suite.

# Tasks: fix-faceless-cage-vertices

## 1. Dropping face-less vertices

- [x] 1.1 `Mesh.prunedOfFacelessVertices()` — rebuild through `append`, since the C API has
      no "drop this vertex" entry point and `append` already preserves vertex sharing.
- [x] 1.2 `Mesh.facelessVertexIDs()` for diagnostics and tests.
- [x] 1.3 The whole-mesh solve prunes before symmetry and before the ghost reports any id.
      A failed rebuild falls back to the unpruned cage.
- [x] 1.4 The region path deliberately does NOT prune: its interface vertices and
      solved-face ids name that handle, and its patch is cleaned by the merge's `append`.

## 2. Saying so

- [x] 2.1 `MeshEditController.relaxChangedNothing`, naming both immovable cases.
- [x] 2.2 Emitted when a relax stroke journaled nothing — including the case where it never
      mutated at all.

## 3. Tests

- [x] 3.1 A face-less vertex is found and dropped; faces and positions and sharing survive.
- [x] 3.2 A clean mesh is untouched.
- [x] 3.3 A payload round trip PRESERVES a face-less vertex — why it has to be dropped at
      the source.
- [x] 3.4 THE REGRESSION: a whole-mesh solve on the reported mesh returns no face-less
      vertices. Fails without 1.3.
- [x] 3.5 A relax that changes nothing reports it; one that works stays quiet. Fails
      without 2.2.
- [x] 3.6 Mirrored onto the device target.

## 4. Device verification

- [x] 4.1 Run the mirrored suites on the iPad.
- [ ] 4.2 Re-solve the bunny and check the cage's vertex count against F + 2, then relax the
      ear tip: either it moves, or it says why not.

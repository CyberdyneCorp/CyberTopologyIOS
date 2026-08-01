# Tasks: add-patch-selection-scope

## 1. Finding a patch

- [x] 1.1 `QuadPatch.faces(containing:in:)` — flood fill bounded by separatrices, mesh
      boundary, and non-quad faces. Pure over the public Mesh API, so it is unit-testable.
- [x] 1.2 Separatrix tracing: from every irregular vertex, walk each incident edge STRAIGHT
      (at a valence-4 vertex the next edge is the one belonging to neither face of the edge
      walked in on) until another irregular vertex or a boundary.
- [x] 1.2a The valence that counts as regular DEPENDS on where the vertex sits: 4 inside, 3
      on a boundary. Treating every rim vertex as irregular raked a separatrix inward from
      each one and left every face its own patch — caught by 4.2.
- [x] 1.3 A non-quad seed selects only itself.

## 2. The gesture and the mark

- [x] 2.1 `PencilTapAction.selectPatch` when no region tool is armed.
- [x] 2.2 A face-id hover query, not gated on the move scope: a double-tap over a face means
      the face, even standing near one of its vertices.
- [x] 2.3 Selection state on the controller, published to the viewport.
- [x] 2.4 A gold fill over the selected faces, through the existing region-fill geometry.
- [x] 2.5 Tapping a selected face removes its patch; tapping elsewhere adds one.
- [x] 2.6 The selection drops when the cage's topology changes.

## 3. Scoping the commands

- [x] 3.1 Snap All and Relax All scope by PINNING the complement.
- [x] 3.2 Triangulate scopes by building the triangles before deleting the quads.
- [x] 3.3 The four Clear commands scope to annotations inside the selection.
- [x] 3.4 Subdivide / Subdivide + Reproject / Halve stay whole-cage and say so.
- [x] 3.4a REPORTED FROM DEVICE: the note was OVERWRITTEN by the command's own report, so
      a declining Halve showed only its refusal and the ignored selection went unmentioned.
      The note now travels with whatever the command reports.
- [x] 3.4b The all-quad refusal names the offending faces by count. The rule alone does not
      locate a handful of triangles in a 315-face cage.
- [x] 3.5 The selection's size is announced when it changes.
- [x] 3.5a REPORTED FROM DEVICE: the announcement was not enough — the panel still read
      "Run on the whole EditMesh" with a patch selected, and Subdivide quietly took the
      whole cage. The header now names the reach, and every command that will ignore the
      selection carries a "whole cage" badge BEFORE it runs.
- [x] 3.5b A Halve refusal SELECTS the faces in its way: one triangle in a 317-face cage is
      a needle, and a count does not locate it. Also "1 triangles" was on screen.

## 4. Tests

- [x] 4.1 A patch on a regular grid; the fill stops at a separatrix; a non-quad seed.
- [x] 4.2 A flat open grid is ONE patch (16 of 16), and a fully regular closed cage (a
      torus) is one patch too.
- [x] 4.3 Add/remove by re-tapping.
- [x] 4.4 Scoped relax moves the selection and NOT its complement.
- [x] 4.5 Scoped triangulate leaves unselected quads intact.
- [x] 4.6 Scoped clear-pins keeps pins outside the selection.
- [x] 4.7 Subdivide and Halve declare themselves whole-cage, and the notice names the
      reason rather than only the fact.
- [x] 4.8 The selection empties after a topology change.

## 5. Device verification

- [x] 5.1 Run the mirrored suites on the iPad.
- [ ] 5.2 Double-tap an ear patch: the gold block is the grid region, not the whole bunny,
      and Relax All then evens out only that.

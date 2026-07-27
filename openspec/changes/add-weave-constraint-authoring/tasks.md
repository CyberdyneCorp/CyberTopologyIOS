# Tasks: add-weave-constraint-authoring

Staged so the cheapest evidence lands first. The bridge (task 1) makes two constraint kinds
real with almost no new surface; frozen authoring (task 3) is the only genuinely new UI; the
density brush and radial symmetry (task 5) are gated on a type decision and may split out as
5.2b rather than be forced into this change.

## 0. Correct the stale record first

- [x] 0.1 5.2a's blocker text says pins and tagged loops have "no SOURCE to read them from
      until regional solve (5.1a) lands". 5.1a HAS landed. Fix the master entry, and fix
      5.5a's "doubly blocked" to singly-blocked (on 5.2a alone).
- [x] 0.2 Record what already exists, so nobody rebuilds it: `MeshAnnotations`
      (`pinnedVertices`, `taggedEdges`, `tagColorIndices`, `Codable`), `MeshIDCompaction`
      pin remapping, `EditMeshOverlay` pin rendering, the `pinFlip` tool, the `tagLoop`
      stroke verb, `togglingPins`/`togglingTags`, `taggedEdgesByColor()`.

## 1. The bridge: authored annotations reach a region solve

- [x] 1.1 Read the EditMesh's `MeshAnnotations` where `WeaveConstraints` is constructed
      (`WeaveFillSession`, `AutoRetopoSession`) and populate `pinnedVertices`.
- [x] 1.2 Group each colour's tagged edges into loops and populate `taggedLoops`.
      `taggedEdgesByColor()` gives the grouping by colour; walking a colour's edge set into
      ordered loops is the only new logic. A colour whose edges do NOT form a loop must be
      handled explicitly (supplied as an open chain, or refused with a reason) — not
      silently dropped.
- [x] 1.3 Filter to the solved region. Annotations outside it constrain geometry the solve
      does not touch, and supplying them would misreport what constrained the result.
- [x] 1.4 **Prove the pin is not dropped.** A test asserting "the solve succeeded with pins
      supplied" would pass if the bridge silently discarded them. Assert instead that an
      interior pin makes the solve DIFFER from the same solve without it, and that the
      pinned vertex's position survives.

## 2. Define the interface-pin case

- [x] 2.1 An interior pin constrains position; an interface pin becomes an
      `interfaceValence` prescription (the field that already exists for exactly this
      purpose) rather than a redundant position constraint — the interface position is
      already bitwise-guaranteed by `RegionSolve`'s `vertexPinned` mask.
- [x] 2.2 Test that an interface pin does NOT weaken exact landing: the bitwise interface
      assertions from 5.3 must still hold with pins supplied.
- [x] 2.3 Make the distinction observable to the caller rather than implicit, so a pin that
      was reinterpreted as a valence prescription can be seen to have been.

## 3. Frozen-face authoring

- [x] 3.1 Add `frozenFaces` to `MeshAnnotations`, following pins exactly so it inherits
      `Codable` persistence, id compaction, and undo instead of a parallel mechanism.
- [x] 3.2 Authoring verb + overlay. The solver half needs nothing: `RegionWeaveSolver`
      already subtracts `constraints.frozenFaces`.
- [x] 3.3 Bridge frozen faces into `WeaveConstraints.frozenFaces`.
- [x] 3.4 Tests: a frozen face survives the solve unchanged; freezing every face of the
      region refuses with a reason and publishes nothing; frozen state survives save/reload;
      frozen state survives id compaction.

## 4. Regression proof (the load-bearing half)

- [x] 4.1 A whole-mesh solve stays BYTE-IDENTICAL — no annotation may leak into the
      whole-mesh path. This is the null-object property that made 5.1a safe and it must not
      regress.
- [x] 4.2 Empty annotations ⇒ byte-identical to today, so the bridge is provably inert when
      nothing is authored.
- [x] 4.3 No interface golden regenerated. If one changes, the bridge has altered exact
      landing and that is a defect, not a golden to refresh.

## 5. Density and symmetry breadth — RESOLVED: multi-axis landed, two split to 5.2b

- [x] 5.1 **Decided: per-vertex scale multipliers.** `isotropic.cpp` already sizes every
      split/collapse against `targetEdgeLength * 0.5 * (scaleOf(scales,a) + scaleOf(scales,b))`
      — a per-vertex array in the `kScaleAttribute` vertex attribute — so spatially varying
      density is NOT a new engine capability; the consumer exists and is proven by the
      adaptivity path. What is missing is an author-supplied SOURCE: `computeTargetScales`
      fills the array from curvature alone. Rejected: painted texture (needs a
      parameterisation the EditMesh lacks mid-solve, and resamples to vertices anyway),
      falloff stamps (a source for scales, not a model — can sit on top later), per-face
      scalars (the consumer averages edge endpoints, so it converts to vertices at the
      boundary). Split to **5.2b** because it needs a C API channel plus an engine decision
      on how an authored scale COMPOSES with curvature adaptivity. Recorded in
      `add-weave-density-radial-symmetry`.
- [x] 5.2 **MULTI-AXIS LANDED; radial split to 5.2b.** Multi-axis turned out small because
      `applySymmetry(_:snapping:)` already reduced over `mirrorAxes` and mirrored a quadrant
      into all four — the only single-axis part was the solver's CLIP, which became an
      intersection of half-spaces (the working orthant), with each seam snapped to its own
      plane so a vertex on the orthant EDGE welds onto both. Also corrected a scoping error
      in this change's own proposal: `SymmetrySettings` already carried `mirrorAxes` as a
      sorted LIST plus `radialCount`/`radialAxis`, so the model was never the gap — only
      what the solver honoured. Radial genuinely does not reduce to half-space clipping: its
      domain is an angular SECTOR and its seams need `rotationalWeld`, not a mirror weld.
- [x] 5.3 Split as **5.2b** = `add-weave-density-radial-symmetry`, carrying the density
      brush and radial symmetry with the reasons stated, rather than closing 5.2a while
      parts of it remain undone.

## 6. Validation

- [x] 6.1 `openspec validate --changes --strict`; full simulator suite; engine suite via
      `build_engine.sh --host-tests`.
- [x] 6.2 Device run for the annotation-bridge tests — and unlike previous runs, confirm the
      iPad is unlocked with Auto-Lock set to Never FIRST, and capture the full log with
      `-resultBundlePath`. A filtered log reduces to a bare `** TEST FAILED **` with no
      diagnosis possible.
- [x] 6.3 Update the master entry to say which of the six kinds are honoured end to end
      after this change, counted explicitly rather than described.

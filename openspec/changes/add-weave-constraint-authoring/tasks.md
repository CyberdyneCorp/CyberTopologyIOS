# Tasks: add-weave-constraint-authoring

Staged so the cheapest evidence lands first. The bridge (task 1) makes two constraint kinds
real with almost no new surface; frozen authoring (task 3) is the only genuinely new UI; the
density brush and radial symmetry (task 5) are gated on a type decision and may split out as
5.2b rather than be forced into this change.

## 0. Correct the stale record first

- [ ] 0.1 5.2a's blocker text says pins and tagged loops have "no SOURCE to read them from
      until regional solve (5.1a) lands". 5.1a HAS landed. Fix the master entry, and fix
      5.5a's "doubly blocked" to singly-blocked (on 5.2a alone).
- [ ] 0.2 Record what already exists, so nobody rebuilds it: `MeshAnnotations`
      (`pinnedVertices`, `taggedEdges`, `tagColorIndices`, `Codable`), `MeshIDCompaction`
      pin remapping, `EditMeshOverlay` pin rendering, the `pinFlip` tool, the `tagLoop`
      stroke verb, `togglingPins`/`togglingTags`, `taggedEdgesByColor()`.

## 1. The bridge: authored annotations reach a region solve

- [ ] 1.1 Read the EditMesh's `MeshAnnotations` where `WeaveConstraints` is constructed
      (`WeaveFillSession`, `AutoRetopoSession`) and populate `pinnedVertices`.
- [ ] 1.2 Group each colour's tagged edges into loops and populate `taggedLoops`.
      `taggedEdgesByColor()` gives the grouping by colour; walking a colour's edge set into
      ordered loops is the only new logic. A colour whose edges do NOT form a loop must be
      handled explicitly (supplied as an open chain, or refused with a reason) — not
      silently dropped.
- [ ] 1.3 Filter to the solved region. Annotations outside it constrain geometry the solve
      does not touch, and supplying them would misreport what constrained the result.
- [ ] 1.4 **Prove the pin is not dropped.** A test asserting "the solve succeeded with pins
      supplied" would pass if the bridge silently discarded them. Assert instead that an
      interior pin makes the solve DIFFER from the same solve without it, and that the
      pinned vertex's position survives.

## 2. Define the interface-pin case

- [ ] 2.1 An interior pin constrains position; an interface pin becomes an
      `interfaceValence` prescription (the field that already exists for exactly this
      purpose) rather than a redundant position constraint — the interface position is
      already bitwise-guaranteed by `RegionSolve`'s `vertexPinned` mask.
- [ ] 2.2 Test that an interface pin does NOT weaken exact landing: the bitwise interface
      assertions from 5.3 must still hold with pins supplied.
- [ ] 2.3 Make the distinction observable to the caller rather than implicit, so a pin that
      was reinterpreted as a valence prescription can be seen to have been.

## 3. Frozen-face authoring

- [ ] 3.1 Add `frozenFaces` to `MeshAnnotations`, following pins exactly so it inherits
      `Codable` persistence, id compaction, and undo instead of a parallel mechanism.
- [ ] 3.2 Authoring verb + overlay. The solver half needs nothing: `RegionWeaveSolver`
      already subtracts `constraints.frozenFaces`.
- [ ] 3.3 Bridge frozen faces into `WeaveConstraints.frozenFaces`.
- [ ] 3.4 Tests: a frozen face survives the solve unchanged; freezing every face of the
      region refuses with a reason and publishes nothing; frozen state survives save/reload;
      frozen state survives id compaction.

## 4. Regression proof (the load-bearing half)

- [ ] 4.1 A whole-mesh solve stays BYTE-IDENTICAL — no annotation may leak into the
      whole-mesh path. This is the null-object property that made 5.1a safe and it must not
      regress.
- [ ] 4.2 Empty annotations ⇒ byte-identical to today, so the bridge is provably inert when
      nothing is authored.
- [ ] 4.3 No interface golden regenerated. If one changes, the bridge has altered exact
      landing and that is a defect, not a golden to refresh.

## 5. Density and symmetry breadth — GATED, may become 5.2b

- [ ] 5.1 `DensityField` is a single `targetEdgeLength: Float`, so it CANNOT express a
      spatially varying brush. Decide the spatial model (per-face scalar? painted texture?
      falloff stamps?) BEFORE building any brush UI, and record the decision.
- [ ] 5.2 Multi-axis symmetry composes with the existing clipping strategy (clip to an
      octant). RADIAL does not reduce to clipping at all and needs a different solver
      approach — do not bundle the two as if they were one task.
- [ ] 5.3 If either lands outside this change, split it as **5.2b** with the reason stated,
      following this repo's split-out-honestly pattern rather than closing 5.2a while parts
      of it remain undone.

## 6. Validation

- [ ] 6.1 `openspec validate --changes --strict`; full simulator suite; engine suite via
      `build_engine.sh --host-tests`.
- [ ] 6.2 Device run for the annotation-bridge tests — and unlike previous runs, confirm the
      iPad is unlocked with Auto-Lock set to Never FIRST, and capture the full log with
      `-resultBundlePath`. A filtered log reduces to a bare `** TEST FAILED **` with no
      diagnosis possible.
- [ ] 6.3 Update the master entry to say which of the six kinds are honoured end to end
      after this change, counted explicitly rather than described.

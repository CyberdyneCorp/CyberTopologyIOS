# Constraint authoring: make the stored constraint taxonomy real

## Why

`WeaveConstraints` stores all six constraint kinds so call sites and the document are
forward-compatible, but only three are honoured end to end (guide strokes, density as a
global preset, single-axis symmetry). 5.2 shipped those; 5.2a is the remainder, and it is
the largest functional gap left in Phase 5.

**The gap is not what the roadmap says it is.** Scoping it by reading the code rather
than the task text turned up five findings, and three of them shrink the work
substantially:

1. **Pins and tagged loops are already authored, persisted, and rendered.** `MeshAnnotations`
   carries `pinnedVertices`, `taggedEdges` and `tagColorIndices`; it is `Codable` so they
   survive save/load; `MeshIDCompaction` remaps pins across id compaction; `EditMeshOverlay`
   draws pinned vertices; the `pinFlip` tool and the `tagLoop` stroke verb author them, with
   `togglingPins`/`togglingTags` as the ops. What is missing is only the **bridge**: nothing
   populates `WeaveConstraints.pinnedVertices` or `.taggedLoops` at solve time. Grepping the
   two session files that construct `WeaveConstraints` for `annotations` returns ZERO hits —
   they pass `guideStrokes` and `symmetry` and nothing else. So two of the six kinds are a
   wiring-and-proof job, not a feature build.

2. **The roadmap's stated blocker is stale.** 5.2a says pins and tagged loops have "no
   SOURCE to read them from until regional solve (5.1a) lands". 5.1a has landed. The
   blocker text must be corrected rather than left to mislead the next reader.

3. **Frozen faces: the solver half is done, the app half is genuinely absent.**
   `RegionWeaveSolver` already subtracts `constraints.frozenFaces` from the region, and
   freezing an entire region is an explicit refusal rather than a silent whole-region solve.
   But `frozen` appears in `App/Sources` only inside a comment — there is no authoring verb,
   no annotation field, and no overlay. This one is real new surface.

4. **The density brush needs a MODEL change, not a UI.** `DensityField` is a single
   `targetEdgeLength: Float`. A scalar cannot express spatially varying density, so a brush
   is structurally impossible against today's type — this is not a matter of adding a
   gesture. Calling it "density is a global preset, not the spec's density brush" understates
   it.

5. **Symmetry breadth is a small type change with a large solver question.**
   `SymmetrySettings.Axis` is a single `x`/`y`/`z` case, and the solver honours one mirror by
   clipping to the working side. Multi-axis composes (clip to an octant); RADIAL does not
   reduce to clipping at all.

## What changes

Ordered so the cheapest evidence lands first.

**The bridge.** On a region solve, read the EditMesh's `MeshAnnotations` and populate
`pinnedVertices` and `taggedLoops`. `taggedEdgesByColor()` already groups the edges;
grouping a colour's edge set into loops is the only new logic. This converts two kinds from
stored-and-never-read into honoured, and it is provable against the region-solve harness
that already exists.

**One design question the bridge must answer, not dodge.** `RegionSolve` ALREADY pins every
interface vertex (the `vertexPinned` mask is what makes exact landing bitwise). So a
user-authored pin on an interface vertex is redundant, while a pin in the region INTERIOR is
new information. And `interfaceValence` exists precisely so an authored pole is not reported
as irregular. The bridge therefore has to define what an authored pin MEANS in each
position, and say so in the spec, or it will silently do something arbitrary at the exact
place 5.3a is trying to make a guarantee about.

**Frozen-face authoring.** An annotation field, an authoring verb, an overlay, and
persistence — mirroring how pins already work, so it inherits compaction and undo rather
than inventing a parallel mechanism.

**Density and symmetry breadth** are scoped LAST and deliberately: the density brush needs
`DensityField` to become spatial, and radial symmetry needs a solver strategy that is not
clipping. Either could justify its own change once the type question is settled.

## Non-goals

- **Soft/weighted constraints.** Constraints are hard-only today. Weighting is a solver
  semantics change, not an authoring one, and belongs with the constraint-aware backend.
- **Steering the QuadCover/seamless-MIQ path.** Guide/tag steering targets the
  field-aligned quadrangulator; the alternate backend is out of scope here.
- **Changing the exact-landing guarantee.** The bridge must not weaken 5.3's proof; a
  whole-mesh solve must stay byte-identical, and the region interface must stay bitwise.

## Risk

The honest risk is scope: 5.2a as written bundles five different things, and shipping all
five behind one change would produce exactly the "closed but not really" outcome this
project has been correcting. So the tasks are staged, and the change may legitimately close
with density-brush and radial symmetry split out as 5.2b — stated up front rather than
discovered at the end.

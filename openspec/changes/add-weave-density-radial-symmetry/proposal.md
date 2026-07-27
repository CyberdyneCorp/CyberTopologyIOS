# Density brush and radial symmetry (5.2b)

## Why

Split from `add-weave-constraint-authoring` (5.2a) under its task 5.3, which reserved the
right to do exactly this rather than close 5.2a with parts of it undone. 5.2a's four other
sub-gaps landed: pins and tagged loops now reach a region solve, frozen faces are
authorable, and MULTI-AXIS mirror symmetry is honoured. These two did not, for reasons
that are specific rather than "ran out of time".

## The density-brush decision (5.2a task 5.1)

The task said to decide the spatial model BEFORE building any brush UI. Decided:
**per-vertex scale multipliers**, because the engine already consumes exactly that.

`isotropic.cpp` sizes every split/collapse against
`m_options.targetEdgeLength * 0.5f * (scaleOf(scales, a) + scaleOf(scales, b))` — a
PER-VERTEX scale array stored as the `kScaleAttribute` vertex attribute. So spatially
varying density is not a new engine capability; the mechanism is already there and
already proven by the adaptivity path.

What is missing is an AUTHOR-SUPPLIED source for it. Today `computeTargetScales` fills the
array from curvature and `adaptivity` alone, so there is nowhere for a brush to write.

Rejected alternatives, with reasons rather than preferences:

- **Painted texture / UV-space field** — needs a parameterisation the EditMesh does not
  have during a solve, and would have to be resampled onto vertices anyway. That is the
  chosen model with extra indirection.
- **Falloff stamps (position + radius + strength)** — a source for scales, not a model.
  It can be authored ON TOP of per-vertex scales later; it does not replace them.
- **Per-face scalars** — the consumer averages the two endpoint scales of an edge, so a
  face-keyed field would be converted to vertices at the boundary. Same field, worse fit.

**Why it is not in 5.2a:** `DensityField` is currently one `Float`
(`targetEdgeLength`), so this needs the Swift type to gain a per-vertex channel, a C API
entry point to carry it, and an engine change deciding how an authored scale COMPOSES with
the curvature-derived one (multiply? override? clamp?). That composition is a real design
question with visible consequences — an authored coarse region fighting high curvature has
to resolve somehow — and it is engine work (patch 0008), not app wiring.

## Why radial symmetry is not multi-axis

Multi-axis landed in 5.2a and was small, because `applySymmetry(_:snapping:)` already
reduced over `mirrorAxes` and mirrored a quadrant into all four. The only single-axis part
was the solver's CLIP, which became an intersection of half-spaces.

Radial does not reduce to that. Its working domain is an angular SECTOR — a wedge bounded
by two half-planes meeting at the radial axis, with the sector count deciding the angle —
not an intersection of half-spaces. And closing it needs rotational seam welding
(`rotationalWeld`, which exists for the BAKE path) rather than the mirror weld
`snapToSymmetryPlane` performs. Treating it as "one more axis" would silently produce a
mesh that is not radially symmetric.

`SymmetrySettings` already carries `radialCount` and `radialAxis`, so the model is ready;
the solver is what needs the sector clip.

## Non-goals

- Soft/weighted constraints — still 5.2a's non-goal and still a solver-semantics change.
- Changing how multi-axis mirror symmetry works now that it is honoured.

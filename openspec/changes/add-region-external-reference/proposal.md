# Region solves project onto the Target, not onto themselves (5.4b)

## Why

`remeshRegion` builds its `ReferenceSurface` from the mesh it is rewriting:

```cpp
const ReferenceSurface reference(work, params.smoothNormalDegrees);
```

For a Weave Fill, `work` is the cage plus a grown seed band. The seed rows are already
Target-snapped, so the surface is a reasonable approximation — but the solve then REFINES
that seed and reprojects onto the approximation rather than onto the Target itself. Any
Target detail finer than the seed band is invisible to the solve, so it is lost.

The comment in the region branch already admits the shape of the problem for a different
reason ("whole-mesh rather than region-local … on thin or self-close geometry an interior
region vertex can snap to the wrong sheet"), and notes it degrades interior quality rather
than the landing guarantee. 5.4b is the same class of defect: interior quality, not
correctness. Exact landing is unaffected either way, because interface vertices are never
smoothed (Invariant P).

## The premise needs testing first

**The deviation was already measured at 0.031 quads** on `add-weave-region-selection`'s
task-0 spike, which is why 5.4b was filed as a quality item rather than a blocker. That
number is the reason this change opens with a spike instead of an implementation:

- 0.031 quads is imperceptible. If that is representative, the fix is not worth an engine
  patch, a C API parameter and a per-solve BVH over a multi-million-triangle Target.
- But it was measured on a SMOOTH fixture, where a coarse seed band approximates the Target
  well by construction. The failure mode this change exists to fix is *fine Target detail
  inside a coarse seed band*, which a smooth fixture cannot exhibit.

So the spike measures the deviation on a Target with genuine high-frequency detail, and
measures what an external reference COSTS. Either the gain is real on detailed geometry and
this proceeds, or 0.031 generalises and 5.4b should be closed as "measured, not worth it"
rather than left open forever as a vague quality debt.

## What changes, if the spike justifies it

**Engine (patch 0008):** let the region path accept an external reference surface instead of
always constructing one from the working mesh. The C API carries it by mesh handle, riding
the handle the way `cyber_mesh_set_solve_region` and `cyber_mesh_set_orientation_guides`
already do — an established pattern in this codebase rather than a new one.

**The cost question the spike must answer.** A fill is interactive today precisely because
the working mesh is small; a `ReferenceSurface` over the whole Target is a BVH over millions
of triangles. If that lands on every fill the feature stops being interactive, so the spike
measures build time before any of this is designed around. Caching keyed on the reference
handle is the obvious mitigation, but it is not worth designing until the numbers say the
cost is real.

## Non-goals

- **Filling bare Target that touches no open cage boundary.** Folded into 5.4b's roadmap
  entry, but it is a different mechanism entirely: growing cannot reach it, so it needs the
  carve path (a 4.1a remainder). It is currently refused with a clear reason rather than
  mis-filled, which is the correct behaviour until carve exists. Kept out so this change
  does not become two changes.
- **Changing exact landing.** The interface is bitwise-guaranteed and this must not touch it.
- **The whole-mesh path.** It has no external reference to speak of; the Target IS its input.

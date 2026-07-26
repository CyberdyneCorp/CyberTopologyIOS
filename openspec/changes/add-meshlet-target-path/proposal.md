# Proposal: add-meshlet-target-path

## Why

Task 2.2a is the **last unmet v0.1 exit criterion**: the meshlet/LOD render path on
mesh-shader hardware, plus the 5M-triangle @60fps device acceptance run that the
traceability scenario "Multi-million-triangle target" is still pending on.

The seam for it already exists and is honest: `TargetRenderPathSelection.preferredKind`
returns `.meshlet` on A14/M1+, while `availableKind` deliberately resolves to
`.indexedVertex` because no meshlet pipeline is implemented. Slotting one in needs no
renderer change.

## The assumption nobody has measured

**The task assumes the 5M acceptance requires the meshlet path. That has never been
tested.** The largest device measurement in the repo is
`testLargeReplicatedTargetFrameTimeOnDevice` at **2.1M triangles**, which passes the
60fps budget on the plain indexed-vertex path.

5M is 2.5× that, on an M3 iPad, for a static mesh with no per-frame allocation. It is
entirely possible the fallback path already clears the budget — in which case the
acceptance gate can be met now, v0.1 unblocks, and meshlets become an optimisation
rather than a blocker.

So this change is **measurement-gated**. Task 0 measures the existing path at 5M on
hardware, and its result selects among three very differently-sized outcomes:

- **A — budget already met.** Promote the measurement to an assertion, close 2.2a's
  acceptance clause, and re-scope the meshlet path as a separate performance change
  (still worth doing: headroom for heavier scenes and for the UV/bake stages).
- **B — close but missed** (say 17-25 ms). A meshlet path WITHOUT cluster LOD is likely
  enough: better vertex reuse and per-meshlet frustum/backface culling, no
  simplification, no LOD-crack problem. Bounded, and it fits behind the existing seam.
- **C — badly missed.** Cluster LOD is genuinely required, which is a much larger piece
  of work (per-cluster simplification, LOD selection, crack-free boundaries between
  levels) and should be its own change with its own spike.

Writing the pipeline before knowing which of these is true would risk building C's
machinery to solve an A-shaped problem.

## What Changes

Scope depends on task 0, and the tasks reflect that. Common to all outcomes:

- **A 5M-triangle device measurement** at both a modest and a full-iPad resolution,
  reported with the numbers rather than a pass/fail bit.
- **An honest fixture decision** (see below).
- **Traceability**: the "Multi-million-triangle target" scenario moves out of the
  pending list only when a real assertion covers it.

Outcome-specific work is listed under tasks 2 (A), 3 (B) and 4 (C), of which **at most
one is executed**.

## Design Decision 1 — replicated procedural geometry is not a real Target

The existing harness builds its load with `replicatedGridGeometry`: tiled grids of
identical topology. That is a fair GPU throughput test, and it is **not** representative
of a scan or sculpt — perfect cache locality, uniform triangle size, no varied normals,
no clustering pathology. A meshlet path's whole value is in culling and vertex reuse on
irregular geometry, so measuring it against a perfect grid would flatter it.

Task 0 therefore measures BOTH: the replicated grid (comparable with the existing 2.1M
number) and a subdivided real asset (`armadillo.obj` is already committed at 4.6 MB).
If they disagree materially, the real asset is the number that counts.

A committed 5M-tri OBJ is ~250 MB and is not going in the repo; generating from a
committed smaller asset is the honest middle.

## Design Decision 2 — meshletization belongs in the engine

Design rule D1: no mesh algorithms in Swift. Clustering triangles into meshlets is a
mesh algorithm, so under outcomes B and C it is engine work behind a new C API and a
numbered patch (0007), not a Swift-side loop. The render path consumes the engine's
meshlet buffers exactly as `IndexedVertexRenderPath` consumes index buffers.

## Non-Goals

- **Cluster LOD under outcomes A and B.** It is only in scope if task 0 shows C.
- **Changing the fallback.** `.indexedVertex` remains mandated for the simulator and
  pre-A14 hardware; the meshlet path is additive behind the existing capability gate.
- **The 9.6 release gate itself.** This change supplies one of its measurements.

## Notes

The measurement is currently **blocked**: the iPad Air 13-inch (M3) used for the
previous device run is no longer available to the host, and the perf harness skips on
the simulator by design (GPU timing there is not representative — design D9). Task 0
runs as soon as a device is attached; nothing after it should start first.

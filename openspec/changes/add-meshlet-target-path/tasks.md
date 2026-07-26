# Tasks: add-meshlet-target-path

**Measurement-gated.** Task 0 decides which of tasks 2 / 3 / 4 runs — **at most one of
them.** Do not start any of them first: the whole point is not to build outcome C's
machinery for an outcome A problem.

## 0. Measure the existing path at 5M on hardware (FIRST, and blocking)

- [ ] 0.1 Extend the existing device perf harness (`ViewportPerfTests`, which already
      measures 2.1M through `replicatedGridGeometry` + `measure`) to **5,242,880
      triangles** (`segments: 256, tiles: 40`).
- [ ] 0.2 Measure at TWO resolutions — a modest 1280×960 comparable with the existing
      2.1M number, and the iPad's native 2732×2048, since fill cost scales with pixels
      and the acceptance is about the real viewport.
- [ ] 0.3 Measure a REAL asset too, not only replicated tiles: subdivide the committed
      `App/TestFixtures/armadillo.obj` up to ~5M. Uniform tiles have perfect cache
      locality and uniform triangle size, so they overstate throughput — see design
      decision 1. Where the two disagree materially, the asset is the number that counts.
- [ ] 0.4 Report, per run: triangle count, average and max GPU frame time, whether the
      16.667 ms budget is met, `supportsMeshShaders`, and the preferred vs available
      render path — so a budget met on the FALLBACK path cannot be misread as a meshlet
      pipeline existing.
- [ ] 0.5 Record the numbers in this file and pick the outcome:
      **A** budget met → task 2. **B** missed by a modest margin → task 3.
      **C** badly missed → task 4.
      BLOCKED at time of writing: the iPad Air 13-inch (M3) is not attached, and the
      harness skips on the simulator by design (GPU timing there is not representative,
      design D9). Do not substitute a simulator number.

## 1. Common (whatever the outcome)

- [ ] 1.1 The acceptance measurement becomes an ASSERTING device test, not a reporting
      one, with the explicit-skip discipline the perf harness already uses.
- [ ] 1.2 It asserts no per-frame GPU allocation at 5M, as the 2.1M test does.
- [ ] 1.3 Traceability: move "Multi-million-triangle target" out of the pending list ONLY
      once 1.1 asserts it.
- [ ] 1.4 Record in the master list which render path met the budget.

## 2. Outcome A — the fallback already meets the budget

- [ ] 2.1 Promote the 5M measurement to an assertion; close 2.2a's acceptance clause.
- [ ] 2.2 State plainly in 2.2a that the acceptance was met on the INDEXED-VERTEX path
      and that no meshlet pipeline exists — `availableKind` still resolves to
      `.indexedVertex`, and the seam stays honest.
- [ ] 2.3 Re-scope the meshlet path as its own performance change (headroom for heavier
      scenes, and for the UV/bake stages that will share the GPU), not a v0.1 blocker.

## 3. Outcome B — meshlets WITHOUT cluster LOD

- [ ] 3.1 Engine (patch 0007): meshlet build — cluster triangles into bounded meshlets
      (vertex/primitive caps matching Metal's limits) with per-meshlet bounds and a
      normal cone for backface culling. Engine-side per design rule D1 (no mesh
      algorithms in Swift).
- [ ] 3.2 C API + CyberKit accessors for the meshlet buffers, following the zero-copy
      pointer-view lifetime contract the render buffers already use (Engine/patches/0002).
- [ ] 3.3 `MeshletRenderPath: TargetRenderPath` — object/mesh shader pair, per-meshlet
      frustum and normal-cone culling, pooled buffers, no per-frame allocation.
- [ ] 3.4 `TargetRenderPathSelection.availableKind` returns `.meshlet` when capabilities
      allow AND the pipeline built; a shader-compile failure must fall back rather than
      render nothing.
- [ ] 3.5 Parity: the meshlet path and the indexed path render the same mesh to
      equivalent pixels (offscreen classification, as the existing render-path tests do).
- [ ] 3.6 Re-measure 5M; assert the budget on the meshlet path.

## 4. Outcome C — cluster LOD required

- [ ] 4.1 **Spike first, before any pipeline work**: per-cluster simplification and LOD
      selection are a research-grade feature (crack-free boundaries between adjacent
      clusters at different levels is the hard part, and it is where Nanite-style systems
      spend their complexity). Measure what a simple screen-space-error LOD over
      independently simplified clusters actually looks like at the seams before
      committing.
- [ ] 4.2 If the spike shows visible cracks, this becomes its own change with its own
      design — do NOT extend this one to absorb it.

## 5. Validation

- [ ] 5.1 `openspec validate --changes --strict`.
- [ ] 5.2 Full app-hosted suite green on the simulator AND device; no golden regenerated.
- [ ] 5.3 Engine C++ suite green via `scripts/build_engine.sh --host-tests` (outcomes B/C
      only, since they touch the engine).
- [ ] 5.4 Update `add-cybertopology-app` 2.2a with the measured numbers and the outcome
      taken, and 9.6 with the acceptance result.

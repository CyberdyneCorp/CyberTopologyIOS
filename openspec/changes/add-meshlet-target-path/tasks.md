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
- [x] 0.5 **MEASURED 2026-07-26, iPad Air 13-inch (M3), iOS 26.5.2. OUTCOME B.**

      | geometry | res | avg | fps | worst frame | avg vs budget |
      |---|---|---|---|---|---|
      | synthetic tiles, 5,242,880 tris | 1280×960 | 10.62 ms | 94.2 | 12.06 ms | MET |
      | synthetic tiles, 5,242,880 tris | 2732×2048 | 11.66 ms | 85.8 | 13.36 ms | MET |
      | **armadillo ×3, 4,798,848 tris** | 1280×960 | 14.64 ms | 68.3 | **18.79 ms** | met |
      | **armadillo ×3, 4,798,848 tris** | **2732×2048** | **16.54 ms** | **60.5** | **19.90 ms** | met by 0.13 ms |

      All on the INDEXED-VERTEX fallback path; `supportsMeshShaders` is true and
      `availableKind` still resolves to `.indexedVertex`, so none of this involved a
      meshlet pipeline.

      **Design decision 1 was right, and it changed the answer.** The synthetic tiles
      said 11.66 ms at full resolution; the real asset said 16.54 ms for FEWER triangles
      — the uniform grid overstated throughput by ~42%. Judging the acceptance on the
      synthetic number alone would have closed 2.2a on a measurement that does not
      describe a scan.

      **Why this is B and not A**, despite every row reading "met":
      - the real-asset average clears the 16.667 ms budget by **0.13 ms — 0.8%**, which
        is inside measurement noise, not headroom;
      - the WORST frame is **19.90 ms** at full resolution, i.e. ~50 fps. At 60 Hz that
        is a dropped frame, so "runs at 60fps" would be a claim the user can see is
        false;
      - it is **4.80M triangles, under the 5M target** — the gate asks for at least 5M;
      - there is no budget left for anything else the GPU must do in a real session
        (EditMesh overlay, ghost proposals, subdivision preview) let alone the UV and
        bake stages that will share it.

      → proceed to **task 3** (meshlets WITHOUT cluster LOD). Task 4 is not indicated:
      the gap is ~20-25%, which per-meshlet culling and vertex reuse can plausibly
      cover, and nothing here suggests needing simplification or LOD.
- [ ] 0.6 **Revise the acceptance criterion before asserting it.** The existing perf
      tests assert on the AVERAGE frame time. For a 60fps claim that is too weak: the
      real-asset run has a compliant average and a 19.90 ms worst frame. Task 1.1 should
      assert a high percentile (or the max over a sustained window), because a hitch the
      user sees is a failed 60fps claim however good the mean is.

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

- [x] 3.1 Engine patch **0007**: `core/meshlet.{hpp,cpp}` — deterministic clustering
      (lowest unassigned seed, grow by most-shared-vertices, ties on lower index) with
      64-vertex / 126-triangle caps, a bounding sphere and a normal cone.
      **Operates on the RENDER STREAMS, not `Mesh` topology** — compacted positions plus
      a flat triangle index buffer, i.e. exactly the buffers the renderer binds. That
      way meshlet vertex indices address the same array the position/normal buffers use,
      with no second mapping to keep in sync, and the builder is a pure function that
      needs no half-edge structure.
      **Conservativeness is the load-bearing property and is asserted directly**, not
      inferred from the formulae: a sphere that is too small or a cone that is too tight
      makes the GPU cull geometry the user can see, which shows up as holes. Tests check
      every sphere CONTAINS its vertices and every cone CONTAINS its triangle normals.
      A cluster whose normals span more than a hemisphere declares `coneCutoff = 0`,
      meaning *never backface-cull me*, rather than claiming a cone it cannot honour.
      Malformed input (out-of-range index, ragged count) yields an EMPTY set rather than
      a partially valid one the renderer would draw; degenerate triangles are dropped so
      they cannot widen a cone for no benefit.
      8 tests; engine suite now **289 cases / 129 771 assertions**, and the CI floor was
      raised 281 → 289 so the new tests are covered by the guard too.
- [x] 3.2 C API (`cyber_mesh_meshlets_ptr` / `_meshlet_vertices_ptr` /
      `_meshlet_indices_ptr` + `CyberMeshlet`) and CyberKit `withMeshletBuffers` /
      `meshletCount`, under the same zero-copy pointer-view lifetime contract as the
      render buffers. Clusters are built **lazily on first request**, not with the rest
      of the render cache: clustering a multi-million-triangle Target costs real time and
      the overlay, picking and export paths never ask for it.
      **A LAYOUT BUG, caught by the tests and worth recording.** The Swift `Meshlet`
      first used `SIMD3<Float>` for the vector members. `SIMD3<Float>` is **16 bytes, not
      12** (padded to four lanes), so the struct was 56 bytes against C's 48 and every
      field after `center` sat at the wrong offset. It compiled cleanly and the
      reinterpreted buffer read garbage — `triangleCount` came back as 4,853,069,083 and
      every `radius` as 0. The comment at the time asserted the layout was
      "layout-compatible by construction", which was a claim I had not checked.
      Fixed with 3-Float tuples plus computed `SIMD3` accessors, and
      `Mesh.meshletLayoutMatchesC` is now **asserted by a test** — a mismatch here is
      silent, so it cannot be left to reasoning.
      Also asserted: clusters index the SAME compacted array the position buffer uses
      (out of range would be a GPU read past the end), local corners stay inside their
      own cluster's slice, spheres contain their vertices, a flat mesh yields cones with
      cutoff > 0.99, a back-to-back pair declares itself uncullable, and clusters are
      REBUILT after an edit rather than served stale (the compacted vertex order moves,
      so a stale cluster would draw scrambled geometry).
- [ ] 3.3 `MeshletRenderPath: TargetRenderPath` — object/mesh shader pair, pooled
      buffers, no per-frame allocation.
      **BLOCKED ON A PRODUCT DECISION, found before writing any shader.** The Target is
      currently rendered DOUBLE-SIDED: `ViewportRenderer.swift:894` sets
      `encoder.setCullMode(.none)` and the fragment shader uses `abs(dot(n, -light))`,
      with the comment "double-sided shading, consistent with cull mode none". Someone
      chose this deliberately.
      So **normal-cone backface culling — the biggest expected win — is not currently a
      free optimisation, it is a visible behaviour change.** A back-facing triangle today
      contributes pixels, and for an open shell, a scan with holes, or the inside of a
      concave region seen through an opening, that back face IS the visible surface.
      Culling it would leave a hole in the render.
      What remains safe and unconditional: **vertex reuse** (fewer vertex-shader
      invocations for the same triangles) and **frustum culling** (rejecting clusters
      wholly outside the view). Neither changes a pixel. For a Target filling the
      viewport, though, frustum culling buys little — so the safe subset may not close
      the measured ~20-25% gap on its own.
      Options, in increasing cost to the product:
      **(1)** vertex reuse + frustum culling only — measure, and stop here if it suffices;
      **(2)** additionally backface-cull only when the mesh is WATERTIGHT (no boundary
      edges), which is invisible on a closed scan and simply yields no win on an open one
      — needs a closedness query, which the C API does not have yet;
      **(3)** switch the Target to single-sided rendering — the biggest win, and a
      deliberate change to how open shells look.
      **3.5 (pixel parity) is what would catch any of this going wrong**, which is why it
      runs alongside 3.3 rather than after it.
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

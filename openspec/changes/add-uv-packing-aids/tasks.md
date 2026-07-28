# Tasks: add-uv-packing-aids (6.6)

## 0. Measure before building
- [x] 0.1 Time the existing CPU packer at 50/200/500/2000/10000 islands, both strategies.
- [x] 0.2 Identify the actual cost (O(kCols*span) inner scan x 8 strip widths), not the
      presumed one (throughput).

## 1. Engine — packing speed
- [x] 1.1 Replace the inner per-column maximum with a sliding-window maximum.
- [x] 1.2 Keep the tie-break identical so packed output is byte-for-byte unchanged.
- [x] 1.3 Pick between naive and monotonic-queue scans by a MEASURED span threshold, because
      the asymptotically better version regressed the wide-strip case.
- [x] 1.4 A test pinning that both scan branches agree, so the threshold cannot change results.
- [x] 1.5 Patch-stack entry.

## 2. Engine — packing aids
- [x] 2.1 Pack into a target REGION rather than only the unit square.
- [x] 2.2 C API for region packing, overlap distribution, and per-island flip.
- [x] 2.3 Per-island flipped-winding readback (for the arrows).
- [x] 2.4 Tests: region packing stays inside the region; distribution removes overlaps; a flip
      changes winding and flipping twice is identity.

## 3. CyberKit
- [x] 3.1 `Mesh.packIslands(into:)`, `distributeOverlappingIslands()`, `flipIsland(containing:)`,
      `flippedIslands()`.
- [x] 3.2 Tests, including that a pack preserves each island's internal UVs (the exit criterion).

## 4. App
- [x] 4.1 A pack command, journaled as one step.
- [x] 4.2 Flip arrows in the UV panel for flipped islands, with a one-tap flip.
- [x] 4.3 Overlap distribution reachable, journaled as one step.
- [x] 4.4 Action Gallery entries.

## 5. Close out
- [x] 5.1 validate; engine, simulator, device.
- [x] 5.2 Master 6.6 entry recording the rewritten requirement and the measurements that
      justify it.

## 6. Discovered during implementation
- [x] 6.1 The asymptotically better algorithm was NOT the faster one. The first sliding-window
      version used `std::deque` and made the wide-strip case 2x WORSE (10,000 islands, 95 ms ->
      196 ms) despite removing a factor of `span`; a contiguous vector-backed queue was still
      1.1x worse there. Shipped a measured split between the naive scan and the queue, which is
      why the result improves at EVERY size instead of trading one case for another.
- [x] 6.2 `packIslandsIntoRegion` reported SUCCESS on a mesh with no UVs, having written
      nothing — `packIslands` tolerates a missing column by design, which is fine internally and
      a lie at an API boundary. Found by a capi test that expected a refusal. Fixed with a
      regression test at both layers.
- [x] 6.3 `flippedIslandFaces()` bound `annotations?.seamEdges` with `guard let`, so it returned
      "nothing mirrored" for every cage with NO annotations — the common case. Worse, the test
      covering it passed for that wrong reason. Both fixed; the test now flips an unannotated
      cage and asserts the mirrored island is still reported.
- [x] 6.4 Packing is NOT idempotent with respect to the atlas's own pack (it recomputes island
      bounds from the already-packed UVs and re-normalizes), so the first press legitimately
      moves the layout. What matters is that it SETTLES: the second press is a byte-identical
      no-op and journals nothing, so an artist tapping Pack cannot make the layout creep. The
      test asserts settling rather than the idempotence I first claimed.
- [x] 6.5 Four whole-mesh UV commands now share one `wholeMeshUVCommand` helper. Hand-writing
      the guard/transact/journal/three-way-outcome shape four times would be four chances to get
      the no-op case wrong, and getting it wrong means telling an artist a command failed when
      their layout is already correct.

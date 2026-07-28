# Tasks: add-auto-seam-proposals (6.5)

## 1. Engine
- [x] 1.1 `autoSeams` gains an optional barrier seam set; `computeCharts` will not grow a
      chart across a barrier edge.
- [x] 1.2 Absent barrier = today's behaviour byte-for-byte.
- [x] 1.3 C API returning the proposed edge ids, UNIONED with the barrier so preservation is
      guaranteed even though the merge passes are not barrier-aware.
- [x] 1.4 Patch-stack entry.
- [x] 1.5 Tests: a seam ring bounds the proposal; the barrier's own edges are always present;
      no barrier is unchanged.

## 2. CyberKit
- [x] 2.1 `Mesh.proposedSeams(respecting:)`.
- [x] 2.2 Tests: proposal contains the barrier; a proposal on an already-fully-seamed mesh
      adds nothing surprising.

## 3. App
- [x] 3.1 A propose action; the proposal is held as VIEW state, not document state — it is
      not a document change until accepted.
- [x] 3.2 Proposed seams drawn distinctly from authored ones.
- [x] 3.3 Accept journals ONE `togglingSeams`; discard journals nothing.
- [x] 3.4 Reached through the Action Gallery.

## 4. Close out
- [x] 4.1 validate; engine, simulator, device.
- [x] 4.2 Master 6.5 entry, including the barrier-unaware merge limitation.

## 5. Discovered during implementation
- [x] 5.1 A proposal finding nothing is reported as "no seams needed", NOT as a failure. A
      planar cage legitimately proposes nothing (one chart, no internal chart boundaries), and
      the first draft called that "could not analyse this mesh" — a lie about the artist's
      mesh. Same distinction the unwrap's "already unwrapped" no-op needed.
- [x] 5.2 Accept/Discard had no UI at all: `.proposeSeams` was routed, but nothing could
      accept, so proposing was a dead end. Added a review bar to the UV panel.
- [x] 5.3 The overlay could never redraw for a proposal. `MetalViewport.updateMesh` gates its
      annotation refresh on `object.annotations != overlayAnnotations`, and a proposal changes
      no document annotation, so that comparison is always equal. Added
      `onSeamProposalChanged` — deliberately NOT `onLiveEdit`, since no geometry moved.
- [x] 5.4 `setOverlayAnnotations` gated on a non-nil annotation set, so a proposal on a cage
      with no annotations at all — the likeliest first use — never reached the GPU.

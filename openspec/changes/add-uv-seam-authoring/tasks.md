# Tasks: add-uv-seam-authoring (6.2, first slice)

Engine change is one field. The work is in the document state and the authoring surface.

## 1. Engine

- [x] 1.1 `AtlasOptions` gains an optional supplied `SeamSet`; `unwrapAtlas` uses it in place
      of `autoSeams` when present. Everything downstream — `computeIslands`, LSCM per island,
      packing — already honours a seam set and is NOT touched.
- [x] 1.2 Absent supplied seams must be byte-identical to today, so the capability cannot
      change existing output by existing.
- [x] 1.3 C API: seam edges as a handle side-channel, following
      `cyber_mesh_set_solve_region` / `cyber_mesh_set_density_scales`. Validate ids before
      storing any, so a rejected call leaves the handle untouched.
- [x] 1.4 Fold into the patch stack as a numbered patch.
- [x] 1.5 Engine tests: a seam ring produces its own chart; no supplied seams is unchanged;
      a supplied set is NOT supplemented by auto-seams (chart count follows the seams).

## 2. Document state

- [x] 2.1 `MeshAnnotations.seamEdges`, beside `taggedEdges` and `frozenFaces`, so it inherits
      `Codable` persistence, id-compaction reconciliation and one-undo behaviour. Route
      through `replacing` — the helper that exists precisely so a new field cannot be dropped
      by an unrelated transform.
- [x] 2.2 `togglingSeams(on:)` with the same flip semantics as pins and tags: an all-seam
      selection sews, anything else cuts.
- [x] 2.3 Tests: round-trip; pre-6.2 documents still decode; every transform preserves seams;
      compaction carries them.

## 3. CyberKit

- [x] 3.1 `Mesh.setSeamEdges(_:)` over the C API side-channel.
- [x] 3.2 The unwrap passes the document's seams.
- [x] 3.3 Tests: a seam ring changes the chart count; no seams matches the previous result.

## 4. Authoring surface — NOT DONE, and the honest remainder of this slice

- [ ] 4.1 A seam tool that toggles seams along a stroke, journaled as ONE entry. The document
      state, the engine path and the plumbing are all live and tested — `togglingSeams` exists
      and the unwrap reads `annotations.seamEdges` — so what is missing is the stroke handler
      that turns a Pencil gesture into edge ids. That is the same shape as
      `commitFreezeFlipStroke` and is not blocked on anything.
- [ ] 4.2 Seams drawn distinctly in the EditMesh overlay, respecting hidden faces the way
      tags and pins now do.
- [ ] 4.3 Reached through the Action Gallery.

**Shipping the channel without the gesture is deliberate**: seams are honoured end to end and
provably not supplemented, so the hard half is verified. Nothing claims an artist can draw one
yet.

## 5. Close out

- [ ] 5.1 `openspec validate --changes --strict`; engine, simulator and device suites.
- [ ] 5.2 Update the master 6.2 entry: what shipped, and that corner pinning plus the
      X-gesture are 6.2b. Correct 6.1's "no API to supply seams" claim.

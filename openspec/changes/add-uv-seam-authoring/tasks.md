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

## 4. Authoring surface

- [x] 4.1 `seamFlip`, a stroke TOOL (not an immediate command — it is stroke-driven, so it
      must arm rather than fire once), toggling seams along every edge the stroke crosses,
      journaled as ONE `tool.seamFlip` entry. EDGES rather than faces or vertices, because a
      seam IS an edge set — that is what `computeIslands` treats as uncrossable and what
      `MeshAnnotations.seamEdges` stores; picking a vertex would need an arbitrary rule for
      which incident edge it meant.
- [x] 4.2 Seams drawn in a warm orange, distinct from the tag palette AND from the cold-blue
      frozen outlines, because a seam is a CUT while a tag is a FLOW hint and sharing a
      colour would make two different meanings indistinguishable. Filtered by the same
      hidden-face rule 4.3a added for tags and pins, asserted by test — otherwise a seam on a
      lassoed-away face would keep drawing over whatever is behind it.
- [x] 4.3 Reached through the Action Gallery, with `clearSeams` as an immediate command and a
      batch-panel row beside Clear Frozen.
- [x] 4.4 A screenshot probe, because `visualVerificationProbesJournalEveryTool` requires
      every tool to journal through one — the assertion that correctly rejected the `break`
      first written for `freezeFlip`.

## 5. Close out

- [x] 5.1 `openspec validate --changes --strict`; engine, simulator and device suites.
- [x] 5.2 Update the master 6.2 entry: what shipped, and that corner pinning plus the
      X-gesture are 6.2b. Correct 6.1's "no API to supply seams" claim.

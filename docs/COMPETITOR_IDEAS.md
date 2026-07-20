# Building a Better CozyBlanket — Product Ideas & Design Decisions

> Companion to `COZYBLANKET_REFERENCE.md` (the teardown). This document captures the ideas and decisions for our competitor product. Status: brainstorm consolidated 2026-07-20.
>
> **Decisions already made:**
> 1. **Renderer: native Metal** (no game engine; Metal 3 on iPad/macOS, portable core so a Vulkan/WGPU backend can join later).
> 2. **Engine: CyberRemesherAndUV** — pure C++20 library (github.com/CyberdyneCorp/CyberRemesherAndUV): mesh kernel, field-guided quad remeshing (goal: better than AutoRemesher/Quadriflow), UV, baking, CPU/Metal/CUDA/OpenCL compute backends, Metal/Vulkan viewport. The app is a thin SwiftUI/Metal shell over this engine.
> 3. **Scope:** retopology + UV + baking. No papercraft, no sculpting, no rigging, no rendering. A *preparation* tool.

---

## 1. Positioning

**One sentence:** CozyBlanket's gesture joy + ZRemesher-class automation, fused — you draw the topology that matters, the solver weaves the rest, deterministically.

- **vs CozyBlanket 2.x** (maintenance mode since May 2025): pure manual — the artist does 100% of the labor. We keep its beloved gesture language and remove the labor.
- **vs CozyBlanket Pro** (Rust+WGPU+Candle, closed beta): AI autocomplete, accept-patch-by-patch, black box, tagline "No more puzzle solving" — abandons the manual joy. We offer a *continuum* (assist slider) and a guarantee a neural net can't make: **what you drew is exactly what ships.**
- **Marketing claim to own:** hand-drawn loops are hard constraints, not statistical suggestions. Deterministic, explainable, fully offline.

---

## 2. The Killer Feature: "Weave" — Constraint-Driven Hybrid Retopology

**Mental model: everything you draw by hand is a promise the solver must keep.** The artist authors the ~10% that requires judgment (deformation loops, pole placement, tricky patches); the solver fills the boring ~90% between them. Feature verb: **Weave** (you draw the threads, it weaves the blanket — on-brand against "cozy blanket").

### 2.1 Constraint taxonomy (existing gestures gain solver meaning — no new UX vocabulary)

| Artist draws | Solver constraint |
|---|---|
| Hand-built quads / patches | **Frozen geometry** — verts/faces immutable; patch boundary becomes a hard interface for the solve |
| Color-tagged loops (CozyBlanket already has loop tags) | **Flow constraints** — orientation field must align along them; position-hard or slide-allowed |
| Guide strokes on bare surface (no geometry created) | **Soft orientation hints** — steer edge flow without committing quads |
| Pins | Hard vertex positions |
| Density brush (Pencil pressure = quad size) | Target edge-length field override |
| Symmetry plane | Global mirror constraint on field + extraction |

**Elegant default:** hand-drawn quads implicitly define the sizing field — the solver samples target edge length from frozen patches at the interface, so auto-filled regions match manual scale with no dials. The density brush is only for deliberate overrides.

### 2.2 The hard technical requirement (design for it from day one)

- **Prescribed-boundary quadrangulation.** The interface between frozen and solved regions has fixed vertex count and positions; the integer-grid map must land exactly on those boundary vertices. Parity/count mismatches are resolved by placing singularities **inside** the solve region — never on the interface (no visible seams in edge flow). This is what "run Quadriflow on a sub-mesh and stitch" cannot do (T-junctions, broken loops), and it's the headline claim over AutoRemesher and Quadriflow.
- **Regional, incremental, cancellable, deterministic solve.** Lasso a region → re-solve in ~1s with progress ghost. Same inputs → same output (required for the undo tree, golden-file tests, network sync replay). The region solve is the primitive; "solve all" is just a big region. Do not build a batch-global solver and retrofit interactivity.
- **Licensing:** quad extraction must be clean-room in-house (AutoRemesher's extraction path leans on GPL/libQEx lineage). `tools/license_audit.py` gate stays permissive-only — this is what makes the engine shippable closed-source.

### 2.3 Interaction loop

1. Draw the loops and patches that matter, CozyBlanket-style.
2. Tap **Weave** (or lasso a region + tap) → solver result appears as **ghost geometry**.
3. Tap to accept → ghosts become ordinary EditMesh. Solved topology is not special: every verb (Relax, Tweak, Erase, loop slide) works on it.
4. Don't like a region? Draw another guide stroke or loop through it → region re-solves live around the new constraint.
5. Repeat at any granularity — "weave this armpit" to "weave the whole body."

**Assist slider:** at 0, never tap Weave → pure CozyBlanket puzzle mode. At max, drop one density value and weave the entire mesh → ZRemesher mode. One engine, one continuum.

**Solver ghosts (ambient assist):** when an EditMesh boundary is open, show the solver's proposed next patch as ghost geometry; tap to accept, draw over to override. Same UX as Pro's AI autocomplete, powered by the deterministic field solver — no model download, explainable. A learned prior (ML-initialized orientation fields) can be added *inside* the solver later; constraints still win.

**Precedent (and the gap we fill):** ZRemesher guide curves, Instant Meshes comb tool, polypaint density — pieces exist, but nobody combines **frozen hand-built patches as hard boundary constraints** with an interactive tablet gesture layer. That combination is the product.

---

## 3. Keep From CozyBlanket (their winning principles — don't reinvent)

1. Two-mesh model (immutable hi-poly Target + surface-snapped EditMesh), continuous snap projection.
2. Five coherent verbs — Pencil / Relax / Move / Tweak / Erase — identical semantics across RT / UV / BK stages.
3. Contextual gesture grammar over tool menus; sloppy-stroke forgiveness (draw a square → quad; line across a ring → edge loop; X → delete/unwrap/bake by stage).
4. Hold-chord spring-loaded modifiers; fingers navigate, pen authors.
5. Camera-as-manipulator tools (Extend Boundary, Transform Vertices, Patch Clone).
6. Action Gallery with per-action demo videos; interactive first-run tutorial on a bundled model.
7. Offline-first, no account, no telemetry, documents in user-visible storage.

---

## 4. UV Ideas

- **Auto-seam proposals:** distortion/curvature-weighted graph cut proposes seams as dashed ghosts; accept, erase, or redraw — unwrapper (SLIM/ABF-class) relaxes live. Same promise-keeping model: hand-drawn seams are hard, proposals are ghosts.
- **Live distortion + texel-density heatmaps** on the 3D surface while dragging seams (CozyBlanket shows only a checker).
- **GPU packing on Metal compute** (the engine's `accel/metal` backend) — Pro's headline packer, at our launch. Plus pack-to-region, island grouping, automatic grid straightening.
- **Symmetry-aware UVs:** option to stack mirrored islands (game-standard texel savings) or keep unique. CozyBlanket ignores this entirely.
- **UV-only project type** — unwrap an existing low-poly with no high-poly target. Top user complaint; cheap because stages are decoupled.
- **UDIMs + multiple UV sets** from v1 (matches Pro, beats 2.x).
- Keep their best UV UX: seams drawn on the 3D model, X-gesture unwrap, texture-on-model multitouch transform (move/rotate/scale UVs directly on the surface, then Relax under it).

## 5. Baking Ideas

- **Metal hardware ray tracing** (M3/A17 Pro+; MPS intersector fallback on older chips).
- **Full bake set, not just normals+color:** AO, bent normals, curvature, thickness, position, material/ID maps — Substance-ready inputs on a tablet; nobody has this.
- **Progressive live bake:** low-sample bake continuously updating in the viewport while the cage is edited — instant feedback instead of edit-bake-inspect loops.
- Keep their brush-editable cage (Relax shapes, Tweak per-vertex distance, Erase resets) and draw-a-line high↔low component linking.
- **MikkTSpace-exact tangents**, verified against Blender/Unity/Unreal golden files in the engine's regression suite. Texture→texture rebake (their v2.1 feature) included.

## 6. Apple-Native UX (the Metal decision pays off here)

- **Pencil Pro squeeze** → radial Action Gallery at the pen tip (zero hand travel). **Barrel roll** → rotate the patch/strip/UV island being placed. **Pencil haptics** → the snap/merge feedback users beg for (their #1 "no feedback" complaint).
- **Hover = gesture preview:** before the pen touches, show what the stroke *would* do — ghost quad under a hovering pen, highlighted loop a tap would slide. Preempts their biggest complaint (gesture misfires → undo-retry). Godot could never do this well; native input + Metal can.
- **Post-stroke interpretation chip:** transient chip showing what the recognizer did, with one-tap alternatives — misrecognition becomes a 1-tap fix, not an undo-retry loop.
- **Mesh shaders + MetalFX** for multi-million-tri targets (A14/M1+); unified memory = zero-copy buffers between engine compute and renderer (solver ghosts render with no readback).
- **120 Hz ProMotion**, robust touch-arbitration state machine (pen vs 1/2/3+ fingers), adjustable orbit speed, scale-adaptive clip planes, "camera rescue" gesture — fixes their documented camera chaos.
- **X-ray / see-through EditMesh**, multi-axis + radial symmetry with re-symmetrize, 1–2 level OpenSubdiv preview with reprojection.
- **Ship macOS alongside iPad** (engine already has a desktop shell): universal purchase, same document format. CozyBlanket is iPad-only; Pro will be everywhere — we get there first on the pair that matters.

## 7. Scene & Pipeline

- **Outliner from day one:** multi-object documents, show/solo/lock per component, per-object stats. (Their top-voted review request; Pro adds it — gap validated.)
- **Formats:** OBJ + FBX + glTF + USD(z), multi-object export, UDIM textures — via the engine's `core/io`.
- **Live-link as a superset of their network protocol:** push/pull meshes, camera streaming, remote action buttons (parity) **plus bidirectional edit sync and USD payloads**. Ship Blender add-on + `pip` client at launch; Nomad Sculpt round-trip preset.
- Undo tree (effectively unlimited) + session recovery **always on, even free tier**. Document versions, iCloud/Files sync.

## 8. Business & Positioning

- **Never paywall saving** (their most-hated decision). Free tier: full tools + save; monetize export/bake.
- **Pricing under their $90 cliff:** ~$29 core / ~$59 studio (network, AI/solver packs), one-time; universal iPad+Mac purchase.
- **Localize early:** JP/KR/CN/BR mobile-3D markets — CozyBlanket is English-only after four years.
- **Window:** CozyBlanket 2.x frozen (last release May 2025), Pro in closed beta. Ship before Pro's public launch, architected for Pro parity.

## 9. Engineering Strategy (CyberRemesherAndUV)

- **Benchmark harness vs AutoRemesher / Quadriflow / Instant Meshes:** quad ratio, singularity count, curvature alignment, Hausdorff distance to source, element quality; datasets: Thingi10K + real sculpts/scans. "Better than AutoRemesher and Quadriflow" must be a measured claim.
- **Solver API surface (spec next):** constraint set in → ghost mesh out; progress + cancellation callbacks; regional solve as the primitive; strict determinism.
- **Gesture recognizer:** two-stage (cheap shape classifier → mesh-context resolver); debug HUD during development. Budget ~50% of UX effort here — this subsystem is half the product.
- **Mesh kernel requirements:** half-edge with persistent element IDs (undo tree + sync), geodesic-distance falloff queries, O(loop) boundary/loop iterators, BVH for snap/occlusion.
- **Process:** OpenSpec change proposal for the hybrid-retopo constraint system (`hybrid-retopo-constraints`) — constraint taxonomy, solver API, interface-stitching requirements as capability specs. The repo is already spec-first.

---

## 10. Priority Order (suggested)

| # | Bet | Why first |
|---|---|---|
| 1 | Weave: constraint-driven hybrid solve (§2) | The differentiator; hardest engineering; everything hangs off the constraint API |
| 2 | Gesture layer + recognizer parity with CozyBlanket (§3) | Table stakes for the audience; feeds constraints into #1 |
| 3 | Camera/input robustness + haptics + hover preview (§6) | Attacks their documented weaknesses; cheap goodwill |
| 4 | UV: manual parity + auto-seams + GPU packing (§4) | Second-most-used stage; packer is a Pro headline we can pre-empt |
| 5 | Baking full map set + progressive preview (§5) | Completes the pipeline promise |
| 6 | Outliner, formats, live-link (§7) | Their top review complaints; engine-level, parallelizable |
| 7 | macOS shell, localization, pricing (§6/§8) | Launch multipliers |

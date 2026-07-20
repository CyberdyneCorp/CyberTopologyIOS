# CozyBlanket — Complete Product Reference & Competitive Analysis

> Reference document for building a competitor product. Focus: **retopology, UV mapping, baking, and Apple Pencil UI/UX**. The papercraft feature (v2.1) is deliberately out of scope and only noted where it affects architecture.
>
> Sources: sparseal.com (product, features, network, CozyBlanket Pro pages), US App Store listing + full version history + user reviews, CG Channel coverage, and transcripts of five YouTube reviews/tutorials (askNK, SouthernGFX, My CG Tutor/Aelamation, Small Robot Studio, ProcreateFX "Cozy Blanket 2 — Import/Retopo/UV/Bake"). Compiled 2026-07-20.

---

## 1. Executive Summary

**CozyBlanket** (Sparseal SL, Spain) is an iPad-only app that covers the three most tedious steps of the 3D asset pipeline — **manual retopology, seam-based UV unwrapping, and texture baking** — and turns them into a gesture-driven, "game-like" experience ("like solving a puzzle"). You import a high-poly sculpt (from Nomad Sculpt, ZBrush, Blender, or a 3D scan), draw the new topology directly on its surface with the Apple Pencil, unwrap by drawing seams on the model, pack UVs with multitouch, bake normal maps and vertex colors, and export a game-ready OBJ/STL — all in one app, offline, with no account and no data collection.

It was created by two open-source heavyweights:

- **Pablo Dobarro** — former lead developer of Blender's sculpt mode (Sculpt Mode rewrite, Voxel Remesher, cloth brush, etc.). Deep expertise in mesh editing UX.
- **Joan Fons** — Godot Engine core contributor (rendering). Deep expertise in real-time rendering.

**Tech stack (v1/v2):** built on **Godot Engine**, with a **custom CPU software renderer** so older iPads can display multi-million-triangle targets (performance is bound by iPad RAM, not GPU). GPU rendering is selectable; the CPU path is the fallback/high-poly path.

**Business model:** free download (full toolset on the bundled demo frog, save/export disabled) + one-time IAPs: **Lite $19.99** (import/save/export only), **Standard $89.99** (everything incl. network features), **Standard Upgrade $69.99** (Lite → Standard). No subscription. iPadOS 15+, ~396 MB, English only, 3.4★ (78 ratings, US).

**Timeline:** v1.0 Apr 2022 (retopology only) → v1.3 May 2022 (Action Gallery, customizable toolbar) → v1.4 Jun 2022 (visibility, Auto Relax, LoopInf) → v1.5 Jul 2022 (network API, image targets) → **v2.0 Nov 2022 (stages: RT/UV/BK — UV unwrap, packing, baking)** → v2.1 Jan 2024 (papercraft, texture-to-texture baking) → maintenance releases through May 2025.

**Their own next move (critical competitive intel):** **CozyBlanket Pro** — a **ground-up rewrite in Rust + WGPU + Candle** (in-house AI inference, no third-party AI services), currently in closed beta, targeting **Windows, macOS, Linux, iPadOS, Android and Web**. Headline: real-time **AI topology autocomplete** ("No more puzzle solving"), GPU UV packing, UDIMs, scene outliner, multi-object pipelines. Section 10 covers it in full. Any competitor plan must aim at where Pro will be, not where CozyBlanket 2.1 is.

---

## 2. Product Philosophy (what makes it work — copy these principles)

1. **Gamified drudgery.** Retopology/UV/baking are the least-loved tasks in 3D. CozyBlanket's entire brand is turning them into a relaxing puzzle you do on the sofa. The emotional hook ("cozy") is the product.
2. **Minimal, almost invisible UI.** One toolbar, a top bar, stats readout, symmetry toggle. Everything else is gesture. No menus during the core loop.
3. **Draw the result, not the operation.** You don't pick an "insert edge loop" tool — you draw a line across a quad and a loop appears. You draw an X and faces are deleted (or an island unwraps, or a component bakes — see the gesture grammar, §6).
4. **One coherent verb set across all stages.** `Pencil / Relax / Move / Tweak / Erase` mean the same *kind* of thing in retopo, UV-3D, UV-2D, and baking. Relax smooths topology positions, UV coordinates, or the bake cage identically. This slashes the learning curve.
5. **Camera as a modeling tool.** Several tools (Patch Clone, Extend Boundary, Transform Vertices, Draw Strip) select something, then use **camera movement** as the manipulation — a brilliant adaptation to a device with no cursor and limited chording.
6. **Beginner-friendly onboarding.** Interactive tutorial slides on first launch, an Action Gallery where every action has a help panel with a **looping demo video**, and a bundled practice model (the frog). Reviewers repeatedly say the built-in onboarding makes external tutorials unnecessary.
7. **Trust and privacy.** Fully offline, "Data Not Collected" privacy label, files are plain OBJ in the user's Files app folder, one-time purchase.

---

## 3. Core Architecture Concepts

### 3.1 Two-mesh model
- **Target** — the immutable high-poly reference (sculpt/scan). Rendered with vertex colors and smooth shading; supports multiple components; can also be a **2D image target** (snap topology to a sketch plane).
- **EditMesh** — the low-poly mesh being authored. Every new vertex **snaps to the Target surface** (shrink-wrap projection is implicit and continuous). All retopo tools operate on the EditMesh; UV and bake stages consume it.

### 3.2 Stages (v2.0+)
A document moves through three stages, selected by a vertical `RT / UV / BK` switch on screen edge:

| Stage | Purpose | Viewports |
|---|---|---|
| **RT** | Build the EditMesh on the Target | Single 3D viewport |
| **UV** | Seams, unwrap, layout, pack | Split view: 3D model + 2D UV plane; swipe from either edge to make one side full-screen; drawing a line down the divider re-splits |
| **BK** | Cage editing, high↔low linking, baking | Side-by-side low-poly / high-poly views; light preview |

Multi-viewport support shows the data relevant to the active stage. Stage state, pins, loop tags, occlusion settings, cage distances are all persisted in the document.

### 3.3 Document model
- Auto-save (paid); documents live in a visible `CozyBlanket` folder in the iPadOS Files app.
- Force save & reload; "save new version" (named copy); EditMesh backup/autosave to recover from network errors or bad edits.
- Undo ~30 steps: **two-finger tap = undo**, three-finger tap = redo, plus on-screen buttons (disabled when nothing to undo).

---

## 4. Retopology Feature Reference (RT stage)

### 4.1 Action roster (complete, from the official feature list)

| Action | Behavior |
|---|---|
| **Pencil** | The universal gesture tool: draw to create/edit EditMesh elements (full grammar in §6). |
| **Relax** | Smooths topology toward regular grids. **Corners are auto-pinned** so grid patches keep their shape. Same brush works in UV and BK stages. |
| **Move** | Drag mesh with an area of influence computed **over the EditMesh surface (geodesic)** — disconnected components are not affected. |
| **Tweak** | Move single vertices or **slide edge loops**. Also activated by double-tapping with the Pencil. |
| **Erase** | Delete faces under the stroke; **more Pencil pressure = coarser accuracy** (bigger eraser). |
| **BuildQ** (Build Quad) | Drag from existing topology: from a quad edge → new triangle; from a triangle edge → extends it to a quad; from an interior corner → new quad. New vertices auto-merge onto existing ones on release. |
| **BuildT** (Build Triangle) | Drag from an edge → new triangle; from an interior corner → two triangles. |
| **Clone** (Patch Clone) | Select faces in one stroke, move the camera to reposition, then paste the patch onto another region (with flip option, patch stats panel, repeatable paste). Kills repetition on scales, armor plates, etc. |
| **ExtendB** (Extend Boundary) | Select boundary edges in one stroke, then **move the camera** to extrude quad strips from the boundary. Modes: single extend, extend-once, automatic steps (continuous strip creation while orbiting). Also does **boundary grid fill** and **triangle fans** with draggable anchor icons to control orientation/spawn. Boundary auto-select: hold Pencil on a boundary vertex to grab the whole visible boundary. |
| **StripD** (Draw Strip) | Drag from a boundary quad edge and a quad strip follows the stroke, preserving the source quad's size, merging with existing quads. |
| **TransfV** (Transform Vertices) | Select vertices in a stroke; they lock to **screen space** so moving the camera moves/rotates/scales them over the model; reports how many can re-snap to the surface. |
| **PinFlip** | Toggle pins on vertices (rendered as yellow circles). Pinned vertices are immune to Move/Relax. Gesture also exists to pin a whole edge loop. |
| **MergeP** (Merge Pair) | Draw a line between two vertices to merge/collapse them; between two adjacent triangles to merge into a quad. |
| **VHideL / VShowL** | Lasso-hide / lasso-show **both** Target and EditMesh faces. |
| **LoopInf** (Loop Information) | Inspector: vertex/edge count of the loop under the cursor, boundary length, endpoints, snapping info. Also activated by holding the Pencil over an interior edge. |
| **PathD** (Path Distribute) | Straightens/evenly distributes vertices along the closest path between the first and last vertex of the stroke. |
| **SurfCut** (Surface Cut) | Knife: cut new edges across existing faces; resulting n-gons are auto-triangulated. |

### 4.2 Supporting systems
- **Symmetry:** single toggle (top bar) with a visible symmetry-plane rim on the model; "Apply Symmetry" bakes it; center-line vertices snap to the plane. (Only one axis — a known limitation; Pro adds multi-axis.)
- **Auto Relax:** optional mode that slides/adjusts surrounding topology after every operation to maintain even quad distribution.
- **EditMesh commands panel:** Snap-all, Relax-all, Subdivide, Triangulate, Clear loop tags, Clear pins.
- **Loop tags (colored loops):** draw along a loop to color-code it (green/purple/orange…) as a planning aid for key loops (eyes, mouth, ears).
- **Occlusion & opacity:** EditMesh opacity slider; manual occlusion depth threshold (how deep behind the target surface the wireframe still shows); configurable selection occlusion with back-face culling. (No true X-ray — a complaint.)
- **Partial visibility gestures:** closed shape starting in empty space crossing the mesh → hide that portion; straight line down in empty space → invert visibility; straight line up → show all.
- **Image targets:** import/replace a 2D image as a snapping target — draw flat topology over a sketch to deform elsewhere.
- **Stats readout:** live vertex/edge/face counts (bottom bar), plus UV/mesh vertex-count comparison.
- **Extras:** cylinder-extrusion gesture, edge-rotation gesture (circle over an edge center), edge-loop bridge and partial bridge gestures, quad split/merge gestures, subdivide+reproject on export.

### 4.3 What the retopo loop feels like (from the tutorials)
1. Import decimated sculpt (OBJ, with vertex colors) → 2. toggle symmetry → 3. draw key **edge loops first** (eyes, mouth, nostrils, ears, limb roots), tagging them with colors → 4. connect loops with big quads (draw whole grids in one stroke over blank areas; line through a "blank" quad ring inserts a loop around the whole ring) → 5. hold **Relax** and scrub to even everything out → 6. Tweak/slide to place poles (5-point verts) deliberately, keeping them apart → 7. patch tricky regions (fingers: box the tip, add knuckle loops) → 8. final full-mesh relax → 9. export or move to UV stage. Users report **~10× speedups vs desktop tools** for characters (1 h vs 6 h for a head, per an App Store review).

---

## 5. UV & Baking Feature Reference

### 5.1 UV3D — working on the model (the differentiator)
- **Pencil:** draw over edges to **create seams**; draw over a seam to delete it; draw an **X (or square) on a region → unwrap that island**.
- **Relax:** relax the UVs of the island under the pencil (corner auto-pinning for grid regularity) — this is *live distortion cleanup while looking at the 3D model*.
- **Move:** move an island's UVs by dragging on the 3D surface.
- **Tweak (multitouch):** adjust **position, rotation and scale of the UVs directly on the 3D surface** with pinch gestures — i.e., you rotate/scale the *texture* on the model and watch the checker respond, then relax under it. Reviewers single this out as the most intuitive UV distortion workflow they've seen.
- **Erase:** delete seams under the stroke.
- **Clone:** copy UVs island→island when topology matches (orientation random if ambiguous).
- **MergeP:** draw one island over another, adjusting seams to fit the new boundary.

### 5.2 UV2D — the flat editor
- Split-view with the 3D model; swipe from screen edge to maximize either view.
- **Pencil:** create/delete seams from the 2D side too.
- **Relax / Move:** same semantics, surface-based influence, disconnected islands unaffected.
- **Tweak island grammar:** stroke starting on the **upper part of an island → rotate**; **lower part → scale**; middle → move. Two-finger pinch does move/rotate/scale naturally. **Double-tap on overlapping islands → distributes them along a straight line.**
- **Erase:** deletes seams and merges the corresponding UVs (sews).
- **BuildQ:** **grid-straighten** — converts an island with grid topology into an axis-aligned UV grid.
- **Clone:** copy UVs between topology-matching islands using selected boundary edges as the alignment reference.
- **MergeP:** copy a vertex position to another vertex, affecting the active element (manual stitching/alignment).
- **PSymm (Partial Symmetry):** symmetrize an island's UVs around the vertices under the cursor if compatible topology is found.
- **Vertex mode:** a toggle (shows UV vertex count) switches from island-level to per-vertex Move/Relax/Tweak.
- **Orientation arrows** on each island reveal flipped shells at a glance; one gesture flips them.
- **Packing:** manual (tweak/pinch per island) with **helper tools for overlapping islands and automatic grid straightening**; re-unwrap an island any time with the X gesture. Checker and imported-image texture preview. (Fully automatic packing only arrives in Pro.)
- **UV pins** supported.

### 5.3 BK — Baking
- **Component linking by drawing:** draw a line between a low-poly component and a high-poly component to link them (explicit high↔low bake assignments); **draw an X over a component to bake it**. Baking the whole model is one X in empty space.
- **Cage editing with brushes:** the bake cage is a first-class editable object — **Relax** smooths cage shape, **Tweak** adjusts cage distance with an area of influence (double-tap for per-vertex distance), **Erase** resets it. *Custom cage distance per vertex* is a headline feature — desktop users usually get a single global cage offset.
- **Move = light:** drag to move the scene's main light to inspect the bake (normal-map shading preview) in real time.
- **Outputs:** tangent-space **normal maps** and **color/vertex-color bakes**; correct tangent space and no scale mismatches are explicit promises ("import a high-poly sculpt and export a game-ready asset that looks the same, without pipeline issues such as scale mismatches, tangent space errors and snapping artifacts").
- **Texture-to-texture baking (v2.1):** import a target that already has UVs + a texture, and re-bake onto the new low-poly UV layout.
- Option to export the triangulated mesh used for baking; side-by-side low/high viewports for artifact hunting.

---

## 6. The Interaction Model — Pencil + Touch UX (the crown jewel)

This is what a competitor must match or beat. The model has four layers:

### 6.1 Division of labor
- **Apple Pencil = authoring.** All drawing gestures. Pressure is used (e.g., Erase coarseness). Recommended but not required — every Pencil interaction has a finger fallback ("No Apple Pencil" sessions exist on YouTube).
- **Fingers = navigation.** One-finger orbit, two-finger pinch zoom/pan, double-tap to re-center/frame the model. Procreate/Nomad-compatible muscle memory (two-finger tap undo, three-finger redo).
- **Hold-chords = tool switching without switching.** The toolbar buttons are **spring-loaded modifiers**: hold `Relax` with a finger and scrub the Pencil to relax; release and you're back to Pencil. Two configurable interaction modes: **multitouch hold** (finger holds button) or **Apple Pencil hold** (timeout/hold gestures). Timeout gestures can be disabled. Left-handed mode; toolbar can be moved to the upper half of the screen or either side.
- **Keyboard (optional):** Space=Pencil, Shift=Relax, G=Move, E=Erase, W=Tweak, S=PolyBuild, P=Patch Clone, Ctrl+Z undo — so a Magic-Keyboard user gets desktop-style chords.

### 6.2 The gesture grammar (Pencil vocabulary)
Strokes are interpreted **contextually by shape + what's underneath**:

| Gesture | Context | Result |
|---|---|---|
| Draw a closed square-ish shape | on empty target surface | New quad |
| Draw a grid in one stroke ("up-across-down…") | from existing topology | Row/block of quads filled at once |
| Straight line across a face | quad | Split → inserts edge; across a face ring → **inserts a full edge loop** |
| Line along an existing loop | edges | **Tags/colors the loop** (planning aid) — direction 90° vs along decides split vs tag |
| Scribble/squiggle over an edge | interior edge | Deletes/dissolves the edge (tri pair → quad) |
| **X** over faces | RT | Delete faces |
| **X** over a region | UV | Unwrap island |
| **X** over a component | BK | Bake it |
| Line vertex→vertex and back | two verts / two loops | Merge/snap them; back-and-forth between loops bridges/merges strips |
| Double-tap on vertex/edge | anywhere | Tweak: move vertex / slide edge loop |
| Circle over an edge center | edge | Rotate edge (change loop flow direction) |
| Line over 3+ boundary vertices | boundary | Activates ExtendB |
| Hold on a boundary edge | boundary | Activates StripD |
| Hold over an interior edge | edge | LoopInf inspector |
| Hold on a boundary vertex | fully visible boundary | Auto-select entire boundary |
| Closed lasso from empty space crossing the mesh | viewport | Hide that portion |
| Straight line down / up in empty space | viewport | Invert visibility / show all |
| Swipe from screen edge | UV stage | Maximize 3D or 2D view; line down the middle re-splits |
| Two-finger tap / three-finger tap | anywhere | Undo / redo |

Sloppy strokes are accepted — recognition tolerates imprecision, and *that forgiveness is the product*. When recognition fails, the documented workaround is "orbit slightly and redraw" (see pain points).

### 6.3 Customizable toolbar + Action Gallery
- The **Action Gallery** is a menu of all actions; **drag** an action into one of **14 toolbar slots** (small=1 slot, large=2), drag onto an existing button to replace it, drag off to remove. Double-tap in the gallery to quick-assign. Tap once → **help panel with a demo video** and usage notes. Configuration persists across sessions (users report a bug: it sometimes doesn't).
- This solves the "toolbar real estate on a tablet" problem: ~19 actions, ~7 visible, user-curated.

### 6.4 Feel and performance targets
- **120 Hz** on iPad Pro (ProMotion); stroke-to-geometry latency is effectively imperceptible.
- Wireframe rendering and its animations were specifically optimized ("much faster wireframe rendering and updated wireframe animations", v2.0) — the EditMesh overlay animates pleasingly when created/edited (reviewers: "the colors… it's just a nice software").
- Viewport resolution downscale option to save battery / boost performance on old devices.

---

## 7. Performance & Rendering Architecture

- **Godot Engine** base (scene, input, UI), with a **custom CPU rasterizer** for the high-poly target ("CozyBlanket has a separate CPU renderer" — confirmed by the developers on r/godot). Rationale: iPad GPU memory/thermals choke on multi-million-tri sculpts + wireframe overlays; a tuned CPU renderer with the mesh in RAM scales with the iPad's unified memory instead. Render mode (GPU/CPU) is user-selectable in Retopology Pack; GPU path got later optimizations.
- **Optimized geometry importer**; handles "production-ready VFX sculpts or photoscans"; explicit claim: performance is **bound by available RAM**, not vertex-count limits (import vertex-count cap was removed in v1.5).
- EditMesh batch operations, scene-depth calculation, and pin drawing all got dedicated optimization passes (version history) — the EditMesh data structure is clearly a half-edge-style structure with fast boundary/loop queries (LoopInf, boundary auto-select, loop slide are all instant).
- No cloud, no telemetry; everything on-device.

---

## 8. I/O, Pipeline & Desktop Integration

### 8.1 File I/O
- **Import:** OBJ (with vertex colors; multiple color sources handled), import-as-new-target or replace-target, import OBJ **as EditMesh** (resume work on an existing low-poly), imported image textures (target color / reference), image targets for 2D snapping.
- **Export:** OBJ (+ always-generated .mtl, normals written), STL, **subdivide + reproject on export** (export a smoothed, re-projected higher-density version), export triangulated bake mesh, baked textures; exports organized into an `Export` folder. Notable gap: **no FBX/USD/glTF, no multi-object export** (top user request).

### 8.2 Network protocol (Standard edition) — the pipeline moat
CozyBlanket can be **remote-controlled over the local network**; the app becomes a peripheral of the desktop DCC:

- Commands: push/load target geometry, pull/load EditMesh, clear scene, close document, display messages on the iPad, create/delete **remote action buttons** (custom buttons on the iPad UI that fire callbacks in your desktop script), query symmetry state, query EditMesh changes, **stream the iPad viewport camera to the desktop in real time**.
- **Python module** (`pip install cozyblanket`): reference client — `CozyBlanketConnection()`, `target_push_obj()`, `editmesh_pull_obj()`, `remote_actions_add()`, `remote_actions_process()` polling loop — plus a CLI.
- **Blender add-on** (3.0+, N-panel): push targets ± EditMesh, pull EditMesh to active object, **real-time sync of EditMesh and camera into Blender**.
- **ZBrush plugin** (experimental, Windows): push SubTool / pull EditMesh.

This makes CozyBlanket "a native retopo viewport for Blender that happens to be a tablet." A competitor should treat two-way live sync as table stakes and improve on it (bidirectional edits, USD, wireless + cable, multi-object scenes).

---

## 9. Known Weaknesses & User Pain Points (the opportunity list)

From App Store reviews and all four long-form videos — these are the gaps a competitor should attack:

**Scene & data management**
1. **No scene outliner.** Can't toggle visibility of individual target components; only lasso-hide or isolate. Top-voted review request. (Pro adds an outliner — validating the gap.)
2. Opaque save model — auto-save to an app folder with no explicit "Save As" mental model; **saving locked behind purchase** (work is lost in the free tier if a bug strikes — users are vocal about this).
3. No multi-object documents, no FBX, no per-object export.
4. No UV-only workflow for an existing low-poly *without* a high-poly target (partially addressed in 2.1 texture-to-texture; still clunky).

**Input & camera**
5. **Palm rejection is imperfect** — stray touches trigger UI actions; >2 simultaneous touches make the camera zoom erratically; camera can get stuck inside the model with no reliable recovery (double-tap re-frame exists but reportedly fails intermittently).
6. **Gesture recognition degrades** when zoomed out, far from the target surface, or in tight/concave regions (finger/ear folds); users learn to "orbit and retry." Recognition ambiguity (tag-loop vs split-loop depends on stroke direction) trips beginners.
7. No adjustable camera orbit speed; poor handling of very small/very large scene scales (small objects clip the near plane; users pre-scale ×10 in Blender).
8. **No snapping feedback** — no visual/haptic/audio confirmation when vertices snap or merge (askNK explicitly compares to desktop tools that beep).

**Editing features**
9. No X-ray/see-through of the EditMesh against the target.
10. Single-axis symmetry only; no "apply mirror then continue asymmetric" workflow polish (apply exists; re-establishing symmetry later doesn't).
11. No subdivision preview levels (users want at least one smooth-preview level while retopologizing).
12. Undo depth (~30) considered shallow for long sessions.
13. No reference-image import in the RT viewport (image targets exist but serve a different purpose).
14. Gestures needed for grids of exactly N strips (e.g., converting a 5-strip to 3-strip junction) are fiddly; reviewers resort to manual vertex merges.

**Commercial**
15. **$89.99 price friction** is the single most common complaint; $19.99 Lite is seen as fair, the jump to Standard is not. A $30–50 full tier, or subscription-optional dual pricing, would undercut them.
16. iPad-only. Android tablets, Apple Silicon Macs with trackpad/pen displays, and Windows pen devices (Surface, Wacom) are unserved — exactly why Sparseal is rewriting in Rust/WGPU for Pro.

---

## 10. CozyBlanket Pro — Where the Incumbent Is Going

Announced ~Nov 2023 concept ("Uniform" was a separate app), Pro publicly unveiled and in **closed beta** (as of early 2026). It is **not an update** — new codebase, new file format, separate product. Pricing TBA.

**Tech stack:** **Rust + WGPU + Candle** (HuggingFace's Rust ML framework — on-device inference). Compiles for Windows, macOS, Linux, iPadOS, Android, Web. All algorithms proprietary/in-house; explicitly **no third-party AI services** (offline inference as a selling point).

**Feature set (from sparseal.com/cozyblanket-pro):**
- **AI topology prediction:** continuously analyzes high- + low-poly meshes and offers **real-time autocomplete patches** — fill whole regions with clean quads in one click; hole repair with proper loop rerouting and pole placement; **draw guide lines on the mesh to steer edge flow**, results adapt instantly. Tagline: "No more puzzle solving. No tools, no gestures to learn."
- **Precision PolyBuild** (point-place/fill, quad drag, edge drag, configurable vertex/edge/face-center snapping) + a **selection-based poly-modeling toolkit** (edge-loop insert, dissolve, slide, knife, n-gons).
- **Multi-axis symmetry** with configurable origins/rotations.
- New high-performance viewport (millions of polys, loop-flow tags, partial visibility, vertex colors, automatic occlusion threshold).
- **GPU compute UV packing** ("thousands of islands… trillions of layout combinations per second") + manual packing tools (transform cages, pack-to-region, grid distribution); 3D-view seam marking with **texel-density visualization**; standalone UV-unwrapping product positioning (export just layouts).
- **Baking:** AO + normals + vertex colors, **custom normals with sharp/smooth edge handling**, custom cage meshes, **UDIMs** with standard naming, multiple UV sets, multi-texture-set single-pass bakes, side-by-side debug viewports with per-map previews.
- **Pipeline:** multi-object scenes with outliner (solo/mute), per-object stats, configurable exporter (meshes, scenes, packed textures, UDIMs), and a coming "Bridge" for scene transfer between Sparseal apps and desktop DCCs.

**Strategic read:** Sparseal is (a) fixing every pain point in §9, (b) going cross-platform, and (c) betting that AI autocomplete replaces the gesture grammar as the core value. The window for a competitor is now, while Pro is in closed beta and CozyBlanket 2.x is in maintenance mode (last release May 2025) — but the competitor must be architected for parity with Pro, not with 2.1.

---

## 11. Blueprint for a Better Competitor

### 11.1 Positioning
"CozyBlanket's delightful pencil UX + the pipeline features it never shipped + AI assistance + cross-platform." Keep the *game feel*; remove the walls (price cliff, iPad-only, single object, no outliner, OBJ-only).

### 11.2 Product principles to preserve (don't out-feature yourself into a desktop app)
1. Two-mesh model with implicit continuous surface snapping.
2. The five coherent verbs (Pencil/Relax/Move/Tweak/Erase) reused across stages.
3. Contextual gesture grammar over tool menus; sloppy-stroke forgiveness.
4. Hold-chord spring-loaded modifiers; fingers navigate, pen authors.
5. Camera-as-manipulator tools (ExtendB/TransfV/Clone) — uniquely tablet-native.
6. In-app Action Gallery with per-action demo videos; interactive first-run tutorial on a bundled model.
7. Offline-first, no account, no telemetry, files in user-visible storage.

### 11.3 Where to be strictly better (mapped to §9)
| Gap | Competitor feature |
|---|---|
| Scene management | Outliner from day one: multi-object documents, per-component show/solo/lock, groups; per-object stats |
| Camera chaos | Robust touch arbitration state machine (pen vs 1/2/3+ fingers), adjustable orbit/zoom speed, scale-adaptive near/far planes + auto-reframe, "camera rescue" gesture |
| Palm rejection | Pencil-priority input filtering + rejection zone around the pen hover point (use PencilKit-grade hover on M2+ iPads / pen hover on Android) |
| Snap feedback | Haptic tick (Core Haptics) + micro-animation + optional click on vertex merge/snap; colorized snap-target highlight before commit |
| Gesture failures | Show a transient "interpretation chip" after each stroke (what the recognizer did) with one-tap alternatives — turns misrecognition into a 1-tap fix instead of undo-retry |
| X-ray | True x-ray/onion-skin EditMesh mode + configurable occlusion, plus retopo-through-surface for thin shells (front-face-only snapping toggle) |
| Symmetry | Multi-axis + radial symmetry, re-symmetrize tool, symmetry-aware UVs |
| Subdiv preview | 1–2 level OpenSubdiv preview with reprojection |
| Undo | Effectively unlimited undo tree, session recovery always on — **even in the free tier** (never lose work; monetize export, not save) |
| Formats | OBJ + FBX + glTF + USD(z), multi-object, multiple UV sets, UDIM textures |
| UV-only mode | First-class "unwrap an existing low-poly" project type (no target required) |
| Price | Free (full tools, watermarked/limited export) → ~$29.99 core → ~$59.99 studio incl. network/AI packs; upgrade paths that don't sting |
| Platform | Cross-platform core from day one (see 11.4); ship iPad first, Android/desktop fast-follow |
| AI | Match Pro: on-device quad-autocomplete + guided edge-flow (guide-stroke conditioned patch suggestion), auto-seam suggestion, one-tap auto-pack — but keep manual gestures as the primary UX and AI as *suggestions rendered as ghost geometry you accept with a tap* (preserves the puzzle joy Pro is abandoning; "assist mode" slider is a differentiator vs Pro's "no more puzzle solving") |

### 11.4 Technical architecture recommendation
- **Core in Rust** (or C++20 if it fits your team better): mesh kernel, gesture recognizer, UV solver, baker — platform-agnostic library. UI shell per platform (SwiftUI/Metal on iPadOS; the user's note that CozyBlanket used **Godot** shows a game engine works, but Sparseal themselves abandoned it for Rust+WGPU — follow their conclusion, not their v1).
- **Renderer:** WGPU (Metal/Vulkan/DX12/WebGPU) with a **meshlet/LOD path for the high-poly target** instead of a CPU rasterizer — modern iPads/GPUs make the CPU-renderer trick unnecessary; keep an out-of-core / compressed vertex-stream strategy so RAM remains the only ceiling. Dedicated fast wireframe/overlay pipeline (barycentric-based, animated) — the overlay *feel* matters.
- **Mesh kernel:** half-edge with persistent element IDs (for undo tree + network sync), geodesic-distance queries (Move/Relax influence), fast boundary/loop iterators (LoopInf-class queries must be O(loop)), BVH over the target for continuous snap projection and occlusion queries.
- **Gesture recognizer:** two-stage — cheap geometric classifier (closed loop / line / scribble / X / circle / lasso) + context resolver against the mesh under the stroke; expose a debug HUD during development; log anonymized *local* recognition failures to tune tolerance. This subsystem is 50% of the product; budget accordingly.
- **UV:** ABF++/SLIM-style relax solver (matches their corner-pinned Relax behavior), seam graph as first-class data, GPU rectangle-packing (genetic/NFP hybrid) to match Pro's packer, texel-density overlay.
- **Baking:** GPU ray-cast bake (embree-class BVH on desktop, Metal ray tracing on iPad) with per-vertex cage, MikkTSpace tangents (bit-exact with Blender/Unity/Unreal — their "no tangent errors" promise, made verifiable).
- **AI assist:** small transformer/graph model for patch autocomplete conditioned on boundary loops + guide strokes, quantized for on-device inference (Core ML / Candle / ONNX Runtime); train on quad-mesh datasets + synthetic decimation pairs. Never require network.
- **Sync protocol:** superset of theirs — WebSocket/QUIC service with push/pull mesh (delta-compressed), camera streaming both directions, remote actions, **plus live bidirectional edit sync and USD payloads**; ship Blender/Maya/ZBrush plugins and a `pip` client from day one.

### 11.5 Scope guardrails
- No sculpting, no rigging, no rendering — stay a *preparation* tool (their focus is why it works).
- Papercraft: skip (per project decision).
- English-first but localize early (CozyBlanket is English-only after 4 years — cheap differentiation in JP/KR/CN/BR markets where mobile 3D is big).

---

## Appendix A — Pricing & Editions (CozyBlanket, US)
| Tier | Price | Contents |
|---|---|---|
| Free | $0 | All tools on bundled frog + own imports; no save/export |
| Lite ("Base I/O") | $19.99 | Import with vertex colors, autosave, OBJ export |
| Standard ("Retopology Pack") | $89.99 | Everything: full action roster, network features, STL, subdivide+reproject, image targets, patch clone, erase, etc. |
| Standard Upgrade | $69.99 | Lite → Standard |

## Appendix B — Version-history milestones worth studying
- **1.1:** keyboard shortcuts, 120 FPS, redo, 30-step undo.
- **1.2:** Tweak & BuildQ as tools, edge-rotate gesture, split/merge gestures, cylinder gesture, apply symmetry.
- **1.3:** Action Gallery + customizable 14-slot toolbar (help videos per action), ExtendB, StripD, TransfV, PinFlip, MergeP, bridge gestures, EditMesh command panel.
- **1.4:** lasso visibility, occlusion/opacity controls, Auto Relax, LoopInf, BuildT, boundary grid fill with anchors, boundary auto-select, force save/versioning, viewport downscale.
- **1.5:** network API (remote control, camera streaming, remote actions), image targets, pinned-loop gesture, gesture accuracy pass, movable toolbar, timeout-gesture toggle, no import vertex cap, redesigned store.
- **2.0:** stages (RT/UV/BK), multi-viewport, smooth shading + vertex colors on targets, per-component visibility, new theme, fast wireframe.
- **2.1:** papercraft (excluded), texture-to-texture baking, target meshes with UVs, packer fixes, saved occlusion settings.

## Appendix C — Source links
- Product: https://sparseal.com/cozyblanket/ · Features: https://sparseal.com/cozyblanket/features/ · Network: https://sparseal.com/cozyblanket/network
- Pro: https://sparseal.com/cozyblanket-pro/
- App Store: https://apps.apple.com/us/app/cozyblanket/id1608079174
- CG Channel: “iPad app CozyBlanket puts the fun back into retopology” (May 2022); “Pablo Dobarro releases CozyBlanket 2.0” (Nov 2022); “Sparseal unveils Uniform” (Nov 2023)
- Videos: askNK detailed review (fzCi86BTZDo) · SouthernGFX (ptmgrce9Qk4) · My CG Tutor 67-min full retopo session (Jg6UKArAn6c) · Small Robot Studio (ABnzjepReLg) · ProcreateFX playlist incl. “Cozy Blanket 2 — Import/Retopo/UV/Bake” (72tvNiymwyM) · short lI0JX310KfM
- r/godot: “Made with Godot: CozyBlanket has a separate CPU renderer”

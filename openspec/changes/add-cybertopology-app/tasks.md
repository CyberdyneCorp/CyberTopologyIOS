# Tasks: add-cybertopology-app

Phased to match the priority order in `docs/COMPETITOR_IDEAS.md` §10. Each phase ends in a runnable vertical slice.

## 1. Foundation — project + engine bridge

- [x] 1.1 Create Xcode project (SwiftUI, iPadOS target; working title CyberTopology), repo scaffolding, CI (build + `openspec validate --all --strict`)
- [ ] 1.1a Test infrastructure: XCTest + XCUITest targets, simulator test job per PR, >90% coverage gate per layer (xccov/llvm-cov), `tests/traceability.yaml` scenario→test map with CI check for unmapped scenarios (spec: quality-assurance)
- [ ] 1.1b Stroke-fixture recorder/replayer for gesture integration tests; golden-file harness (Weave/tangents/bakes) (spec: quality-assurance)
- [ ] 1.2 Integrate CyberRemesherAndUV: submodule/xcframework build, `CyberKit` Swift package façade, smoke test calling an engine mesh op from Swift
- [ ] 1.3 Document model: bundle format, `UIDocument` integration, Files-app-visible folder, autosave + crash recovery, named versions (spec: document-model)
- [ ] 1.4 Undo journal on persistent element IDs; two/three-finger tap undo/redo (spec: document-model)
- [ ] 1.5 OBJ import (vertex colors) as Target and as EditMesh; OBJ+MTL export — minimal I/O for dogfooding (spec: scene-pipeline)

## 2. Viewport — Metal renderer

- [ ] 2.1 Metal viewport: MTKView/CAMetalLayer host, camera (orbit/pinch/reframe, adjustable speed, scale-adaptive clip planes, camera rescue) (spec: viewport-rendering)
- [ ] 2.2 High-poly Target pipeline: meshlet/LOD path on mesh-shader hardware + fallback; smooth shading + vertex colors; 5M-tri @60fps acceptance test (spec: viewport-rendering)
- [ ] 2.3 EditMesh overlay pipeline: animated wireframe, verts/pins/tags, opacity, occlusion threshold, x-ray mode (spec: viewport-rendering)
- [ ] 2.4 Ghost-geometry render style + zero-copy engine buffer sharing (spec: viewport-rendering)
- [ ] 2.5 120 Hz ProMotion pacing, resolution scale option, MetalFX (spec: viewport-rendering)

## 3. Input & gesture layer

- [ ] 3.1 Touch/Pencil arbitration state machine (pen vs 1/2/3+ fingers, palm rejection, hold-chords); finger fallback for all pen gestures (spec: pencil-interaction)
- [ ] 3.2 Engine gesture recognizer integration: stroke sampling → shape classifier → mesh-context resolver; interpretation records; dev debug HUD (spec: pencil-interaction)
- [ ] 3.3 Five verbs wired in RT: Pencil/Relax/Move (geodesic falloff)/Tweak/Erase with continuous Target snapping (specs: pencil-interaction, retopology-tools)
- [ ] 3.4 Full gesture grammar: quad draw, grid stroke, loop insert/tag, scribble dissolve, X delete, merge line, double-tap tweak/slide, edge rotate, visibility lasso/lines (spec: pencil-interaction)
- [ ] 3.5 Post-stroke interpretation chip with one-tap alternatives (spec: pencil-interaction)
- [ ] 3.6 Hover previews (ghost quad, loop highlight, snap-target highlight) (spec: pencil-interaction)
- [ ] 3.7 Haptics on snap/merge (Core Haptics + Pencil Pro); squeeze radial gallery; barrel-roll rotate (spec: pencil-interaction)
- [ ] 3.8 Customizable toolbar + Action Gallery with per-action demo videos; persistence (spec: pencil-interaction)

## 4. Retopology tools

- [ ] 4.1 Build Quad / Build Triangle / Merge Pair / Path Distribute / Surface Cut (spec: retopology-tools)
- [ ] 4.2 Camera-as-manipulator tools: Patch Clone, Extend Boundary (all modes + grid fill + fans + auto-select), Draw Strip, Transform Vertices (spec: retopology-tools)
- [ ] 4.3 Pins (vertex + loop) and loop tags; Loop Info inspector (spec: retopology-tools)
- [ ] 4.4 Multi-axis + radial symmetry, apply-symmetry, re-symmetrize (spec: retopology-tools)
- [ ] 4.5 Auto Relax; batch commands (snap-all, relax-all, subdivide, triangulate, clears, subdivide+reproject) (spec: retopology-tools)
- [ ] 4.6 Subdivision preview (1–2 levels, reprojected) (spec: retopology-tools)

## 5. Weave — constraint-driven hybrid solve

- [ ] 5.1 Define/land solver API in engine (region + constraints → ghost mesh; progress, cancel, determinism contract); golden-file tests (spec: weave-solver)
- [ ] 5.2 Constraint plumbing from app: frozen patches, tagged loops, guide strokes, pins, density brush, symmetry (spec: weave-solver)
- [ ] 5.3 Prescribed-boundary interface guarantee: engine tests for exact boundary landing, interior-only singularities (spec: weave-solver)
- [ ] 5.4 Ghost accept/override flow + lasso-region solve UX; live regional re-solve on constraint edit (spec: weave-solver)
- [ ] 5.5 Implicit sizing from frozen interfaces; global density for full-mesh solve (spec: weave-solver)
- [ ] 5.6 Ambient assist mode (boundary next-patch ghosts, disableable) (spec: weave-solver)
- [ ] 5.7 Benchmark run vs AutoRemesher/Quadriflow/Instant Meshes; publish numbers backing the marketing claim (spec: weave-solver)

## 6. UV stage

- [ ] 6.1 Stage switcher + split view (swipe maximize, line re-split); UV-only project type (specs: document-model, uv-workflow)
- [ ] 6.2 Seam authoring 3D+2D, X-gesture unwrap, engine unwrap/relax solver with corner pinning (spec: uv-workflow)
- [ ] 6.3 On-surface UV manipulation (relax/move/pinch transform with live checker) + 2D island grammar, vertex mode, grid straighten, clone, stitch, partial symmetry (spec: uv-workflow)
- [ ] 6.4 Distortion + texel-density heatmaps (spec: uv-workflow)
- [ ] 6.5 Auto-seam ghost proposals respecting manual seams (spec: uv-workflow)
- [ ] 6.6 Metal-compute packing + manual aids (pack-to-region, grouping, overlap distribute, flip arrows) (spec: uv-workflow)
- [ ] 6.7 Symmetry-aware island stacking; multiple UV sets + UDIM tiles (spec: uv-workflow)

## 7. Baking stage

- [ ] 7.1 BK stage UI: side-by-side low/high viewports, draw-to-link components, X-to-bake, light-drag preview (spec: baking)
- [ ] 7.2 Brush-editable per-vertex cage (Relax/Tweak/Erase semantics) (spec: baking)
- [ ] 7.3 GPU bake core: Metal RT + intersector fallback, identical-output tests; normals + color first (spec: baking)
- [ ] 7.4 Full map set: AO, bent normals, curvature, thickness, position, ID (spec: baking)
- [ ] 7.5 Progressive live bake preview (spec: baking)
- [ ] 7.6 MikkTSpace golden-file verification vs Blender/Unity/Unreal; bake-mesh export (spec: baking)
- [ ] 7.7 Texture-to-texture rebake incl. UDIM (spec: baking)

## 8. Scene & pipeline

- [ ] 8.1 Outliner: show/solo/lock, groups, per-object stats; composition with lasso visibility (spec: scene-pipeline)
- [ ] 8.2 Importers: FBX, glTF/GLB, USD(z); image textures + 2D image targets (spec: scene-pipeline)
- [ ] 8.3 Exporters: STL, FBX, glTF/GLB, USD(z), multi-object, subdivide+reproject, UV sets/UDIM textures, Export folder (spec: scene-pipeline)
- [ ] 8.4 Live-link service (Bonjour + WebSocket): parity command set + camera streaming, off by default (spec: scene-pipeline)
- [ ] 8.5 Bidirectional delta edit sync + USD payloads (spec: scene-pipeline)
- [ ] 8.6 Python pip client + CLI; Blender add-on; Nomad round-trip preset; protocol docs (spec: scene-pipeline)

## 9. Onboarding, monetization, launch

- [ ] 9.1 Interactive first-run tutorial on bundled model (commission asset) (spec: pencil-interaction)
- [ ] 9.2 StoreKit 2 tiers (Free/Core/Studio, difference-priced upgrades, universal purchase), offline fail-open gating; saving never gated (spec: monetization)
- [ ] 9.3 Privacy audit: no telemetry, "Data Not Collected" label; network audit test (spec: monetization)
- [ ] 9.4 macOS shell (Catalyst or native SwiftUI) sharing document format + universal purchase
- [ ] 9.5 Localization scaffolding + first locales (JP/KR/zh-CN/pt-BR)
- [ ] 9.6 Device test plan + release gate: device-only suite (Metal RT, Pencil hover/haptics/squeeze, ProMotion, StoreKit) running on one RT-capable and one baseline device per release candidate, `.xcresult` archived with the tag; cross-environment determinism check (spec: quality-assurance)
- [ ] 9.7 App Store assets, TestFlight beta, `openspec archive add-cybertopology-app` after ship

# Proposal: add-cybertopology-app

## Why

CozyBlanket proved there is a market for gesture-driven retopology/UV/baking on iPad, but it is in maintenance mode (last release May 2025), iPad-only, priced behind a $89.99 cliff, and its successor (CozyBlanket Pro, Rust+WGPU, closed beta) abandons the manual "puzzle" UX for black-box AI autocomplete. There is a window right now to ship a better alternative: CozyBlanket's beloved Pencil gesture language, plus the pipeline features it never shipped (outliner, modern formats, UDIMs), plus deterministic constraint-driven auto-quadrangulation ("Weave") powered by our CyberRemesherAndUV C++20 engine — where everything the artist draws by hand is a hard constraint the solver must keep, not a statistical suggestion.

Full competitive analysis: `docs/COZYBLANKET_REFERENCE.md`. Product decisions: `docs/COMPETITOR_IDEAS.md`.

## What Changes

- New greenfield iPad application (macOS fast-follow): a 3D asset *preparation* tool covering manual + hybrid retopology, seam-based UV unwrapping, and texture baking. No sculpting, no rigging, no rendering, no papercraft.
- Native SwiftUI shell + Metal 3 renderer (no game engine). All mesh/solver/UV/bake algorithms live in the CyberRemesherAndUV C++20 engine (github.com/CyberdyneCorp/CyberRemesherAndUV), consumed as a library.
- Two-mesh document model (immutable high-poly Target + surface-snapped EditMesh) with RT / UV / BK stages, multi-object documents, and an outliner from day one.
- Apple Pencil-first interaction: five coherent verbs (Pencil/Relax/Move/Tweak/Erase) reused across all stages, contextual gesture grammar with sloppy-stroke forgiveness, hold-chord spring-loaded modifiers, hover preview, Pencil Pro squeeze/barrel-roll/haptics.
- **Weave**: constraint-driven hybrid retopology — hand-drawn patches are frozen geometry, tagged loops are flow constraints, guide strokes steer the orientation field; the solver fills regions with prescribed-boundary quadrangulation, rendered as ghost geometry the artist accepts. Regional, incremental, cancellable, deterministic.
- UV stage: seams drawn on the 3D model, live distortion/texel-density heatmaps, auto-seam proposals, GPU (Metal compute) packing, symmetry-aware UVs, UDIMs, UV-only project type.
- Baking stage: Metal ray-traced bakes (normals, AO, bent normals, curvature, thickness, position, ID), brush-editable per-vertex cage, progressive live bake preview, MikkTSpace-exact tangents.
- Pipeline: OBJ/FBX/glTF/USD(z) import/export, multi-object export, live-link network protocol (superset of CozyBlanket's) with Blender add-on and pip client.
- Monetization: free tier always saves (never paywall saving); one-time purchases gate export/bake tiers under CozyBlanket's price cliff.
- Quality bar: >90% unit test coverage enforced in CI, and every feature integration-tested — full suite on the iOS Simulator per PR, device-only plan (Metal RT, Pencil hardware, StoreKit) on physical hardware gating every release.

## Capabilities

### New Capabilities

- `document-model`: documents, two-mesh architecture (Target/EditMesh), stages, multi-object scenes, undo tree, autosave and session recovery, user-visible storage.
- `viewport-rendering`: Metal 3 viewport — multi-million-triangle target rendering, animated wireframe/overlay pipeline, ghost geometry, x-ray/occlusion modes, 120 Hz ProMotion, camera system.
- `pencil-interaction`: input arbitration (pen vs fingers), the five verbs, contextual gesture grammar and recognizer, hold-chord modifiers, customizable toolbar + Action Gallery, hover preview, interpretation chip, haptic feedback, onboarding tutorial.
- `retopology-tools`: RT-stage action roster (build, clone, extend-boundary, strip, transform, merge, pins, loop tags, visibility), continuous surface snapping, multi-axis + radial symmetry, auto-relax.
- `weave-solver`: constraint taxonomy (frozen patches, flow loops, guide strokes, pins, density, symmetry), prescribed-boundary regional quadrangulation, ghost-geometry accept flow, assist continuum, determinism and cancellation guarantees.
- `uv-workflow`: seam authoring (3D + 2D), unwrap/relax solver, island manipulation, distortion/texel-density visualization, auto-seam proposals, GPU packing, UDIMs and multiple UV sets, UV-only projects.
- `baking`: high↔low component linking, brush-editable cage, full map set, progressive live bake, tangent-space correctness, texture-to-texture rebake.
- `scene-pipeline`: outliner (show/solo/lock, per-object stats), import/export formats, export configurations, live-link network protocol and desktop clients.
- `monetization`: free/core/studio tiers, feature gating rules (saving never gated), universal iPad+Mac purchase.
- `quality-assurance`: >90% unit coverage gates, spec-scenario→test traceability, simulator suite per PR, on-device test plan as release gate, determinism/golden-file regression tests.

### Modified Capabilities

_None — greenfield project; `openspec/specs/` is empty._

## Impact

- New Xcode project (SwiftUI app target for iPadOS 17+, macOS target later) — currently the repo contains only `docs/`.
- New dependency: CyberRemesherAndUV (C++20, Swift/C++ interop or a thin Objective-C++ bridge). Engine gaps discovered while building the app become upstream issues in that repo, not app-side forks.
- Engine license gate: quad extraction must remain clean-room/permissive-only (no GPL/libQEx lineage) for closed-source shipping.
- No backend, no accounts, no telemetry — fully offline; the only network surface is the opt-in local live-link protocol.
- Benchmark harness vs AutoRemesher/Quadriflow/Instant Meshes lives in the engine repo; the app consumes its golden-file guarantees.

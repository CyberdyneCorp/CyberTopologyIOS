# Design: add-cybertopology-app

## Context

Greenfield. The repo currently holds only research docs (`docs/COZYBLANKET_REFERENCE.md`, `docs/COMPETITOR_IDEAS.md`). All heavy algorithms (mesh kernel, Weave solver, UV, baking, compute backends) live in the separate **CyberRemesherAndUV** C++20 engine repo; this repo is the Apple-platform shell.

## Goals / Non-Goals

**Goals:** iPad-first (macOS fast-follow) preparation tool — retopology + UV + baking — with CozyBlanket-parity gesture UX and the Weave constraint-driven solver as the differentiator. Offline, no accounts, deterministic.

**Non-Goals:** sculpting, rigging, rendering/look-dev, papercraft, Android/Windows/Web shells (engine stays portable; shells come later), cloud sync beyond iCloud Drive file storage, any server-side component.

## Architecture Decisions

### D1 — Layering: thin Swift shell over the C++ engine
Three layers, strict dependency direction:

```
SwiftUI / UIKit shell        (app UI, documents, StoreKit, Files, Pencil events)
        │  Swift ↔ C++ interop (swift-cxx; Objective-C++ bridge only where interop falls short)
CyberKit (Swift package)     (typed façade: Document, EditMesh, Stroke, Solver, Bake sessions)
        │
CyberRemesherAndUV (C++20)   (mesh kernel, gesture recognizer core, Weave, UV, bake, Metal compute)
```

- **Rule:** no mesh algorithms in Swift; no UI concepts in C++. The gesture *recognizer* (shape classification + mesh-context resolution) is engine code so it is testable headless and portable; the shell only feeds it timestamped stroke samples and renders its results.
- Engine gaps become upstream issues/PRs in CyberRemesherAndUV, never app-side forks.

### D2 — Rendering: native Metal 3, engine-owned scene, shell-owned surface
- The shell owns the `CAMetalLayer`/`MTKView`, display link, and MetalFX; the engine owns geometry buffers and exposes them zero-copy (unified memory) to the renderer — solver ghosts render with no readback.
- High-poly Target path: meshlet/mesh-shader pipeline with cluster LOD on A14/M1+; vertex-pipeline fallback below that. Out-of-core/compressed vertex streams so RAM is the only ceiling.
- Dedicated overlay pipeline (barycentric wireframe, animated) for EditMesh/ghosts/pins/tags — the "feel" is a first-class deliverable, not a debug view.
- Alternative considered: WGPU (like CozyBlanket Pro). Rejected for the shell: we ship Apple-only shells first, and Metal 3 features (mesh shaders, MetalFX, hardware RT, Pencil hover integration) are the differentiators. The engine keeps a Vulkan viewport backend for future non-Apple shells.

### D3 — Weave solver API: regional solve is the primitive
Engine exposes: `solve(region, constraints, params) → ghost mesh` with progress + cancellation callbacks; strict determinism (fixed seeds, ordered reductions, no wall-clock dependence). "Solve all" is a maximal region. Prescribed-boundary quadrangulation (interface vertices fixed, singularities pushed interior) is an engine-level guarantee with golden-file tests. Quad extraction is clean-room in-house — `tools/license_audit.py` in the engine repo stays permissive-only (no GPL/libQEx lineage) so the app ships closed-source.

### D4 — Document format: engine-defined container, file-per-document
Single-file package (directory bundle): engine-serialized meshes with persistent element IDs, seam graph, constraints, stage state, undo journal, thumbnails. Persistent element IDs make undo-tree entries, live-link deltas, and solver replay stable. Stored under the app's user-visible folder; `UIDocument`-based for iCloud/Files integration and conflict handling.

### D5 — Input: single arbitration state machine
One touch/pencil arbiter owns all viewport input: classifies pen vs 1/2/3+ fingers, spring-loaded hold-chords, hover, and camera gestures before anything reaches tools. Recognition is two-stage (cheap geometric classifier → mesh-context resolver, both engine-side). Every stroke produces an *interpretation record* (what matched, alternatives, confidence) that powers the interpretation chip and a debug HUD in development builds. Budget expectation: this subsystem is ~half the UX effort.

### D6 — Baking: Metal RT with graceful fallback
`MTLAccelerationStructure` ray tracing on A17 Pro/M3+, MPS ray intersector fallback on older chips; identical outputs required across paths (golden files). Progressive preview is the same baker at low sample counts writing into a live-updated texture.

### D7 — Live-link: WebSocket + CBOR/flatbuffer frames, Bonjour discovery
Superset of CozyBlanket's protocol (push/pull, remote actions, camera stream) plus delta-compressed bidirectional edit sync and USD payloads. Off by default; Bonjour-advertised only while enabled. Python client + Blender add-on live in this repo under `clients/`.

### D8 — Monetization: StoreKit 2, fail-open gating
Three one-time products (Core, Studio, upgrade by price difference), universal purchase. Entitlement cached locally; transient StoreKit failures never lock a session. Free tier gates *output* (export/bake), never *saving*.

### D9 — Testing: coverage-gated CI, spec-traceable integration tests, device release gate
- **Unit:** >90% line coverage, measured per layer (Swift shell via `xccov`; CyberKit bridge via llvm-cov) and enforced as a failing CI check. Engine algorithms are covered in the engine repo's own suite — the app suite covers the bridge and shell, not re-tests the engine.
- **Integration:** every spec scenario maps to an XCUITest/integration XCTest in a committed traceability file (`tests/traceability.yaml`); CI flags unmapped scenarios. Gesture tests replay recorded stroke fixtures through the real recognizer and assert resulting mesh state — no engine mocks anywhere in integration tests.
- **Environments:** full non-device-only suite on simulator per PR (`xcodebuild test` + parsed `.xcresult`). Device-only plan (Metal RT bake paths, Pencil hover/haptics/squeeze, ProMotion timing, StoreKit) runs on two device classes — one RT-capable (M-series/A17 Pro+), one baseline — as a hard release gate with archived `.xcresult`.
- **Determinism:** golden-file fixtures (Weave outputs, MikkTSpace tangents, bake maps) versioned in-repo; cross-environment bit-identity (simulator vs device) is itself a test.

## Risks / Trade-offs

- **Prescribed-boundary solve is hard research-grade work** → mitigate: it's the engine's headline feature with its own benchmark harness (vs AutoRemesher/Quadriflow/Instant Meshes: quad ratio, singularities, Hausdorff, element quality on Thingi10K + real sculpts); app integrates behind the ghost-accept UX so a slower early solver still ships.
- **Swift↔C++ interop friction** (move-only types, callbacks) → mitigate: CyberKit façade owns all interop; Objective-C++ escape hatch.
- **Gesture recognizer quality is the product** → mitigate: interpretation records + debug HUD from day one; recognition corpus recorded (locally) from dogfooding; tolerance tuning is data-driven.
- **Determinism vs GPU float reduction order** → solver's constraint solve runs deterministic (CPU or fixed-order GPU) even if preview passes don't; only committed geometry must be bit-stable.
- **Scope breadth** → tasks are phased (see tasks.md) matching the priority order in `docs/COMPETITOR_IDEAS.md` §10; UV/BK stages land behind the RT vertical slice.

## Open Questions

- Product name / bundle ID (working title: CyberTopology).
- Minimum OS: iPadOS 17 vs 18 (Pencil Pro APIs and swift-cxx maturity push toward 18; decide at project creation).
- Engine binary distribution into this repo: git submodule + SwiftPM binary target, or source build via CMake → xcframework in CI.
- Bundled practice model (needs a commissioned asset with license for redistribution).
- Exact Studio-tier feature split (live-link placement is a guess until beta feedback).

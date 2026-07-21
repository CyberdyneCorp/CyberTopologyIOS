# CyberTopology

iPad-first retopology, UV unwrapping, and texture-baking tool — a SwiftUI/Metal 3 shell over the [CyberRemesherAndUV](https://github.com/CyberdyneCorp/CyberRemesherAndUV) C++20 engine. Apple Pencil-first gesture UX with **Weave**, a deterministic constraint-driven hybrid retopology solver: everything you draw by hand is a promise the solver must keep.

## Project docs

- [`docs/ROADMAP.md`](docs/ROADMAP.md) — milestones and release plan
- [`docs/COZYBLANKET_REFERENCE.md`](docs/COZYBLANKET_REFERENCE.md) — competitive teardown
- [`docs/COMPETITOR_IDEAS.md`](docs/COMPETITOR_IDEAS.md) — product decisions
- [`openspec/`](openspec/) — specs are the contract; active change: `add-cybertopology-app`

## Development setup

Requirements: Xcode 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) and [Ninja](https://ninja-build.org) (`brew install xcodegen ninja`), CMake ≥ 3.24, Node ≥ 20 with `@fission-ai/openspec` for spec validation.

```sh
git submodule update --init       # engine source: Engine/CyberRemesherAndUV
scripts/build_engine.sh           # engine → Engine/build/CyberRemesherC.xcframework
                                  # (+ copy under CyberKit/Binaries for SwiftPM)
xcodegen generate                 # produces CyberTopology.xcodeproj (not committed)
open CyberTopology.xcodeproj
```

### Engine (CyberRemesherAndUV)

The C++20 engine is a git submodule at `Engine/CyberRemesherAndUV`, built by
`scripts/build_engine.sh` into a static xcframework (device arm64 + simulator
arm64; pass `--sim-only` to skip the device slice, `--force` to rebuild). The
script is idempotent — it no-ops while the artifact matches the submodule
commit — and applies the iOS compile fixes in `Engine/patches/` until they are
merged upstream. An Xcode pre-build phase reruns it on every build, so a stale
engine can never ship.

All engine access from Swift goes through **CyberKit** (`CyberKit/`), a local
SwiftPM package wrapping the engine's C API (`cyber_capi.h`) with a typed
facade (`CyberEngine`, `Mesh`, `RemeshParameters`, `CyberKitError`). Design
rule D1: no mesh algorithms in Swift, no UI concepts in C++ — engine gaps
become upstream issues, never app-side forks. CyberKit's own test suite runs
as part of the app scheme (`CyberKit/Tests/CyberKitTests`).

Build/test from the CLI:

```sh
xcodebuild build -project CyberTopology.xcodeproj -scheme CyberTopology \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO

xcodebuild test -project CyberTopology.xcodeproj -scheme CyberTopology \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)'
```

`project.yml` is the source of truth for the Xcode project — edit it, never the generated `.xcodeproj`, and re-run `xcodegen generate`.

## Process

Spec-driven: implementation follows the tasks in `openspec/changes/add-cybertopology-app/tasks.md`; CI runs `openspec validate --all --strict` plus the simulator build on every PR. Minimum OS: iPadOS 18.

# CyberTopology

iPad-first retopology, UV unwrapping, and texture-baking tool — a SwiftUI/Metal 3 shell over the [CyberRemesherAndUV](https://github.com/CyberdyneCorp/CyberRemesherAndUV) C++20 engine. Apple Pencil-first gesture UX with **Weave**, a deterministic constraint-driven hybrid retopology solver: everything you draw by hand is a promise the solver must keep.

## Project docs

- [`docs/ROADMAP.md`](docs/ROADMAP.md) — milestones and release plan
- [`docs/COZYBLANKET_REFERENCE.md`](docs/COZYBLANKET_REFERENCE.md) — competitive teardown
- [`docs/COMPETITOR_IDEAS.md`](docs/COMPETITOR_IDEAS.md) — product decisions
- [`openspec/`](openspec/) — specs are the contract; active change: `add-cybertopology-app`

## Development setup

Requirements: Xcode 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), Node ≥ 20 with `@fission-ai/openspec` for spec validation.

```sh
xcodegen generate                 # produces CyberTopology.xcodeproj (not committed)
open CyberTopology.xcodeproj
```

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

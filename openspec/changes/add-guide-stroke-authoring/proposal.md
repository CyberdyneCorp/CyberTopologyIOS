# Proposal: add-guide-stroke-authoring

## Why

The engine and CyberKit already honour orientation guides — a guide stroke biases
the Weave cross field so Auto-Retopo edge flow follows it (add-weave-guide-field-
steering, shipped and tested). But there is no way to AUTHOR a guide in the app: the
steering channel is reachable only from code/tests. This change adds the gesture UI —
draw guide strokes on the Target, see them as first-class overlay geometry, and have
the next Auto-Retopo follow them.

## What Changes

- **Guide mode + capture.** A Guide tool/mode; while armed, a pencil (or finger)
  stroke on the Target is captured and each sample raycast onto the Target surface
  (via the existing `SurfaceSnapper`) to a world-space point, producing a world guide
  polyline. Strokes that miss the Target are ignored.
- **A depth-tested Metal line overlay.** A new render path draws the stored guide
  polylines as amber world-space lines, depth-tested against the scene so they sit on
  the Target surface and track the camera as it orbits — a first-class overlay
  alongside the wireframe, pins, and ghost.
- **Auto-Retopo consumes the guides.** The Auto-Retopo trigger threads the stored
  guide polylines into `WeaveConstraints.guideStrokes`, so the proposed cage's edge
  flow follows them. With no guides, behaviour is exactly today's.
- **Clear guides.** An action removes all stored guides in one step.

## Impact

- Affected specs: `weave-solver` (ADDED: authoring guide strokes on the Target;
  Auto-Retopo consumes them).
- Affected code:
  - Rendering: a new `GuideLineRenderPath` (mirroring `GhostRenderPath`) + a
    line vertex/fragment shader; wired into the renderer's overlay draw + `invalidate`.
  - Capture: a Guide mode on the input model; the coordinator raycasts stroke samples
    onto the Target and stores world guide polylines; live ink during the draw.
  - Solve: `beginAutoRetopoAsync` builds `WeaveConstraints.guideStrokes` from the
    stored guides.
  - UI: a Guide-mode toggle and a Clear Guides control.
- Affected tests: guide capture (a stroke over the Target yields a world polyline on
  the surface; a miss yields nothing); the line render path (geometry load / encode,
  headless with the existing skip-if-no-device guard); Auto-Retopo threads guides into
  the solve (the steering itself is already engine-tested).

## Non-Goals

- **Per-guide editing / selection / weight** — guides are draw-and-clear this change;
  individual guide deletion, reweighting, or soft-constraint control is deferred.
- **Persisting guides in the document** — guides are session authoring state (like a
  camera pose), cleared on demand; document persistence is a follow-on.
- **Tagged-loop authoring as flow constraints** — tagged loops live on the EditMesh,
  which whole-Target retopo discards; that needs regional solve (separate).

## Notes

The steering math is done; this change is capture + rendering + wiring. The line
overlay is the largest new surface (a Metal pipeline), modelled on the existing
`GhostRenderPath` so it reuses the renderer's buffer/encode conventions.

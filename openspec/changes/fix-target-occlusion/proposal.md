# EditMesh faces behind the Target are actually occluded

## Why

Reported from device with screenshots: cage faces on the FAR side of the bunny read as if they
were in front of it. A follow-up screenshot of the settings showed **Occlusion depth at its
maximum** and **X-ray mode ON**, and the reporter noted that toggling X-ray "doesn't seem to have
an effect".

The overlay and its fill are depth-tested against the Target with an allowance that pulls them
toward the camera, so a cage snapped ONTO the surface stays visible instead of z-fighting with
it. That allowance is expressed in NDC depth units — and NDC depth is nonlinear, so the same
number buys wildly different amounts of real see-through depending on where the geometry sits:

| Occlusion depth setting | world see-through at the focus | at the far surface |
|---|---|---|
| default (0.002) | 2% of the scene radius | 5% |
| **maximum (0.02)** | **24% of the scene radius** | **48%** |

At the maximum the cage is pulled toward the viewer by nearly half the model's depth. Far-side
faces punch straight through the Target — and X-ray appears to do nothing, because the
depth-tested pass is already drawing everything X-ray would have revealed.

A slider whose maximum DISABLES the feature it is supposed to tune is the defect. The units are
why: no fixed NDC number can mean the same thing twice, because its worth in world units depends
on the near/far planes and on the depth of the fragment being tested.

(An earlier draft of this proposal blamed a collapsing near plane and claimed the default
allowance was 49.5x the model's depth range. That was wrong — it came from a calculation using a
60° field of view where the app uses 50°, which put the camera at 1.99r instead of 2.47r. At the
default framing `near = 0.466` and `far/near = 14`; the default allowance is 1.0% of the model's
NDC depth range. The near-plane floor is still tightened here, but for a narrower reason: when
the camera is INSIDE or very close to the model, `d - 2r` goes non-positive and the old floor
allowed a far/near ratio of 100,000.)

## What Changes

- **The near plane keeps a usable ratio** when the camera is inside or very close to the model:
  floored relative to the far plane so `far/near` stays bounded (1e3 rather than 1e5). This is
  not what caused the report — at the default framing the planes were already healthy — but a
  ratio of 100,000 leaves the depth buffer unable to separate anything.
- **The occlusion allowance becomes SCENE-RELATIVE**: a fraction of the scene radius — "how far
  into the surface may an overlay still show" — converted to an NDC bias per frame at the focus
  depth. The same setting then means the same thing on a 2 mm model and a 200 m one, which an NDC
  number never can.
- **The wireframe and the fill keep sharing it**, so a face's interior is drawn exactly where its
  outline is.
- **X-ray mode is unaffected and becomes meaningful again**: with the allowance no longer
  revealing everything by default, toggling X-ray visibly changes what is drawn — which is what
  the reporter expected and did not get.

Non-goals: no change to the overlay shaders (the conversion is done where the uniforms are
built); no per-object occlusion controls; no change to what x-ray does.

## Capabilities

### New Capabilities

- `viewport-rendering`: EditMesh geometry behind the Target is occluded, with the occlusion
  allowance expressed in scene-relative units and depth precision sufficient to enforce it.

## Impact

- **Affected specs**: `viewport-rendering` (ADDED requirements covering occlusion and depth
  precision).
- **Affected code**: `App/Sources/CameraState.swift` (near-plane floor, the world→NDC bias
  conversion), `App/Sources/EditMeshOverlay.swift` (settings semantics + uniforms),
  `App/Sources/ViewportRenderer.swift` (converts once per frame for wire, fill, ghosts and guide
  lines), `App/Sources/MetalViewport.swift` + `DocumentEditorView.swift` (the setting's range and
  default).
- **Migration**: the stored `overlayOcclusionBias` value changes meaning. An old stored 0.002
  reads as 0.2% of the scene radius — a tighter allowance than before, which is the direction
  this change moves everything anyway, so no reset is needed.
- **Risk**: the near-plane change affects EVERY pass, not just the overlay. Clipping when the
  camera is inside the model is the failure mode to watch, and it is covered by tests at inside,
  fitted and far poses.

# viewport-rendering — Delta Spec

## ADDED Requirements

### Requirement: High-poly target rendering at scale
The Metal viewport SHALL render Targets of multiple million triangles with smooth shading and vertex colors at interactive frame rates on supported hardware (A14/M1 and later), using a meshlet/LOD path where mesh shaders are available. Import size SHALL be bounded by device memory, not by a fixed vertex cap.

#### Scenario: Multi-million-triangle target
- **WHEN** a 5-million-triangle sculpt with vertex colors is imported on an M1 iPad
- **THEN** orbiting the camera SHALL sustain at least 60 fps with smooth-shaded vertex-color display

### Requirement: 120 Hz interaction on ProMotion
On ProMotion displays, pen strokes and their resulting geometry updates SHALL render at up to 120 Hz; stroke-to-geometry latency SHALL be imperceptible (target ≤ one frame of added latency beyond system input latency).

#### Scenario: Stroke latency
- **WHEN** the user draws a stroke that creates a quad on an iPad Pro
- **THEN** the wireframe update SHALL appear within one display frame of stroke recognition

### Requirement: Animated EditMesh overlay pipeline
The EditMesh wireframe and its elements (vertices, pins, loop tags, boundary highlights) SHALL render via a dedicated overlay pipeline with creation/edit micro-animations, configurable opacity, and per-stage color themes. Overlay rendering SHALL remain fluid while the underlying Target is at full density.

Overlay edges and vertex markers SHALL be sized in POINTS, so the cage reads at the same weight on any display scale and at any viewport resolution scale. Edge width is therefore a real parameter, not the hardware's one-pixel line: edges render as screen-space ribbons, since Metal exposes no line width.

#### Scenario: Wireframe animation on creation
- **WHEN** a new quad is created
- **THEN** the new edges SHALL animate in visibly (fade/sweep) without dropping the frame rate

#### Scenario: Cage weight is resolution-independent
- **WHEN** the same EditMesh is rendered on a 2x and a 3x display, or at 100% and 50% viewport resolution scale
- **THEN** its edges and vertex dots SHALL occupy the same physical size on screen in every case

### Requirement: Ghost geometry rendering
Solver proposals (Weave results, auto-seam proposals, autocomplete patches) SHALL render as visually distinct "ghost" geometry (translucent, animated) clearly distinguishable from committed EditMesh geometry, without GPU readback (unified-memory buffer sharing with the engine).

#### Scenario: Ghost vs committed distinction
- **WHEN** a Weave solve completes and its result is displayed alongside committed topology
- **THEN** the proposal SHALL be visually distinct until accepted, and accepting SHALL transition it to the standard EditMesh style

### Requirement: X-ray and occlusion control
The viewport SHALL provide a true x-ray/see-through mode for the EditMesh against the Target, a configurable occlusion depth threshold (how far behind the surface the wireframe stays visible), and automatic occlusion by default.

The occlusion threshold SHALL apply to EditMesh SURFACES (the committed face fill, the hover quad hint) exactly as it applies to the wireframe, so a face and the edges outlining it are occluded together. A surface is snapped onto the Target and can sit at or behind it at any orientation, so this SHALL be enforced in depth space rather than by displacing geometry along its normal — a normal displacement buys no depth clearance at grazing view angles.

#### Scenario: X-ray mode
- **WHEN** x-ray mode is enabled with topology on the far side of the model
- **THEN** far-side EditMesh geometry SHALL be visible with depth-attenuated styling

#### Scenario: A face is not occluded where its own outline is drawn
- **WHEN** an authored quad snapped onto the Target is viewed at a grazing angle
- **THEN** its fill SHALL be visible wherever its wireframe is, rather than the Target showing through an empty outline

### Requirement: Robust camera system
The camera gesture mapping SHALL be: one-finger drag rotates (orbits), two-finger pinch zooms in/out, two-finger drag moves (pans), double-tap reframes. Orbit/zoom speed SHALL be user-adjustable; near/far clip planes SHALL adapt to scene scale (no clipping on very small or very large imports); and a camera-rescue action SHALL always return to a valid framing, including when the camera is inside the model.

#### Scenario: Camera rescue from inside the mesh
- **WHEN** the camera ends up inside the Target and the user invokes camera rescue (or double-tap reframe)
- **THEN** the camera SHALL reframe the model from outside within one animation

#### Scenario: Scale-adaptive clipping
- **WHEN** a 2 mm-scale object is imported
- **THEN** the object SHALL be orbit-able and zoomable without near-plane clipping and without pre-scaling in another tool

### Requirement: Performance controls
The viewport SHALL offer a resolution scale option (battery/thermals) and MetalFX upscaling where available; enabling them SHALL NOT affect gesture recognition accuracy.

#### Scenario: Resolution downscale
- **WHEN** the user sets viewport resolution to 50%
- **THEN** rendering cost SHALL drop accordingly and stroke recognition SHALL behave identically

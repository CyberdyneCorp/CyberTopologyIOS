# uv-workflow — Delta Spec

## ADDED Requirements

### Requirement: Seam authoring on the 3D model and in 2D
Users SHALL create and delete seams by drawing over edges on the 3D model or in the 2D UV editor with the Pencil verb; Erase SHALL delete seams (sewing the corresponding UVs in 2D). An X (or closed square) gesture over a region SHALL unwrap that island; islands SHALL be re-unwrappable at any time. The seam graph SHALL be first-class persisted data.

#### Scenario: Draw seam, unwrap
- **WHEN** the user draws along an edge path on the 3D model and then draws an X over the enclosed region
- **THEN** a seam SHALL be created along the path and the region SHALL unwrap as a new island

### Requirement: Split-view UV layout
The UV stage SHALL show a split view of the 3D model and 2D UV plane; swiping from a screen edge SHALL maximize either side, and a line drawn down the divider SHALL restore the split.

#### Scenario: Maximize and re-split
- **WHEN** the user swipes from the 2D-side edge and later draws a vertical line at the screen middle
- **THEN** the 2D view SHALL go full-screen, then the split layout SHALL be restored

### Requirement: On-surface UV manipulation
In UV3D, users SHALL relax an island's UVs by scrubbing on the 3D surface (corner auto-pinning), move island UVs by dragging on the surface, and adjust island position/rotation/scale via multitouch pinch directly on the 3D surface with live texture feedback. In UV2D, Tweak SHALL support the island grammar (stroke on upper part → rotate, lower → scale, middle → move), per-vertex mode, partial symmetry, grid straightening (Build Quad on a grid island → axis-aligned UV grid), island cloning between matching topology, and manual stitching (Merge Pair).

#### Scenario: Texture-on-model transform
- **WHEN** the user pinch-rotates on an island's surface in UV3D with checker preview active
- **THEN** the island's UVs SHALL rotate live and the checker SHALL update in real time

#### Scenario: Grid straighten
- **WHEN** Build Quad is applied to an island with grid topology in UV2D
- **THEN** the island SHALL become an axis-aligned rectangular UV grid

### Requirement: Live distortion and texel-density visualization
The UV stage SHALL offer, in addition to checker and imported-texture preview, live heatmap overlays on the 3D surface for (a) UV distortion (stretch/shear) and (b) texel density, updating in real time while seams or islands are edited.

#### Scenario: Distortion heatmap while relaxing
- **WHEN** the distortion heatmap is enabled and the user relaxes an island
- **THEN** the heatmap SHALL update live, converging toward the undistorted color as distortion falls

### Requirement: Auto-seam proposals as ghosts
The system SHALL propose seams computed from distortion/curvature analysis, rendered as dashed ghost seams. Hand-drawn seams are hard constraints proposals must respect; users accept, erase, or redraw proposals individually. Proposals SHALL never commit without user acceptance.

#### Scenario: Proposal respects manual seams
- **WHEN** the user has drawn a seam and requests auto-seam proposals
- **THEN** proposals SHALL incorporate the manual seam unchanged and only suggest additional cuts

### Requirement: GPU packing
The system SHALL pack UV islands via Metal-compute accelerated packing with configurable margin, plus manual packing aids: pack-to-region, island grouping, overlap resolution (double-tap overlapping islands → distribute), and orientation arrows revealing flipped shells with a one-gesture flip.

#### Scenario: One-tap pack
- **WHEN** the user invokes auto-pack on a layout of 200 islands
- **THEN** all islands SHALL be packed without overlaps within the target region at interactive speed, preserving each island's internal UVs

### Requirement: Symmetry-aware UVs
For symmetric meshes, the system SHALL offer stacking mirrored islands onto shared UV space or keeping them unique, selectable per island or globally.

#### Scenario: Stack mirrored islands
- **WHEN** the user enables mirrored-island stacking on a symmetric character
- **THEN** left/right island pairs SHALL occupy identical UV space, halving their texel cost

### Requirement: UDIMs and multiple UV sets
Documents SHALL support multiple UV sets per mesh and UDIM tile layouts with standard naming on export; islands SHALL be assignable to tiles.

#### Scenario: Two-tile UDIM export
- **WHEN** islands are distributed across tiles 1001 and 1002 and the user exports
- **THEN** exported UVs and baked textures SHALL follow UDIM conventions with standard tile naming

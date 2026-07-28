# uv-workflow — Delta Spec (add-uv-only-projects)

## MODIFIED Requirements

### Requirement: Split-view UV layout
The UV stage SHALL show a split view of the 3D model and the 2D UV plane. A swipe on the 2D panel SHALL maximize either pane — inward to maximize the 2D panel, outward to maximize the 3D view — and a vertical line down the divider SHALL restore the split.

The layout gesture SHALL be confined to the 2D panel and SHALL NOT be attached to any container
enclosing the 3D viewport: a gesture recognizer above the viewport competes with its camera
recognizers, so every touch beginning over the 3D view SHALL remain with the camera.

The divider line SHALL be recognized only when a pane is maximized. In the split state there is
nothing to restore, and claiming the drag would consume one the 2D island grammar needs.

No maximized state SHALL be a dead end: when the 3D view is maximized the 2D panel SHALL retain a
grab strip, so the gesture that restores the split remains reachable.

Maximizing SHALL be achieved by resizing the panes, never by re-parenting them, because moving the
viewport between containers re-creates its renderer and loses the camera framing.

#### Scenario: Maximize and re-split
- **WHEN** the user swipes inward on the 2D panel and later draws a vertical line down the middle
- **THEN** the 2D view SHALL fill the workspace, then the split layout SHALL be restored

#### Scenario: Maximizing the 3D view stays recoverable
- **WHEN** the user swipes outward on the 2D panel to maximize the 3D view
- **THEN** the 2D panel SHALL retain a grab strip from which the split can be restored

#### Scenario: Camera gestures are unaffected
- **WHEN** the user drags, pinches and double-taps on the 3D viewport in the UV stage
- **THEN** the camera SHALL respond and the split layout SHALL NOT change

#### Scenario: A diagonal drag changes nothing
- **WHEN** a drag on the panel travels equally in both axes
- **THEN** the layout SHALL be unchanged

# Tasks: add-box-region-selection

## 1. The selection

- [x] 1.1 `SelectionBox` — a normalized drag rectangle, direction-agnostic, with a
      meaningful-size test so a tap does not select whatever is under it.
- [x] 1.2 `RegionBoxSelection.faces(in:from:)` — pure: inside the box, in front of the
      camera, facing it. Sorted, because the carve list feeds a solve whose determinism was
      hard won.
- [x] 1.3 `RegionBoxSelection.project` reports points BEHIND the camera rather than letting
      them project to a mirrored point inside the box.
- [x] 1.4 First-hit raycast per candidate excludes faces hidden behind other geometry, which
      a facing test cannot see. Once per drag, not per sample.

## 2. The tool

- [x] 2.1 `RetopoTool.selectRegionBox`, needing only a Target.
- [x] 2.2 Commits at stroke END (the box is only final then), through the same region, the
      same erase mode, and the same paint history as the brush.
- [x] 2.3 The live rectangle is published and drawn, with hit-testing off so it cannot shield
      the MTKView from the drag producing it.
- [x] 2.4 Uses the CACHED Target: it walks every face, and reading the Target from the
      document per use is what made painting lag by seconds.
- [x] 2.5 Action Gallery entry + toolbar slot.

## 3. Tests

- [x] 3.1 Inside/facing/in-front filtering, including a back-facing face and one behind the
      camera.
- [x] 3.2 The selection is sorted.
- [x] 3.3 A tap-sized box selects nothing.
- [x] 3.4 The box is direction-agnostic.
- [x] 3.5 Projection reports behind-camera points and survives a degenerate matrix.
- [x] 3.6 The tool is reachable and is not a camera manipulator.
- [x] 3.7 The journal-probe exemption list grew: like Guide and Paint Region, a box captures
      INTENT and journals nothing.

## 4. Device verification

- [x] 4.1 Run the mirrored suites on the iPad.
- [ ] 4.2 Drag a box over a flank: only the near side is taken, the rectangle tracks the
      drag, a double-tap makes it deselect, and undo removes the box in one step.

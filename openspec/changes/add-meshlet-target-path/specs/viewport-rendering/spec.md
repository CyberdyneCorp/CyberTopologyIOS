# viewport-rendering — Delta Spec (add-meshlet-target-path)

Closes the multi-million-triangle acceptance for the high-poly Target, and states
plainly that the pipeline choice is measurement-led rather than assumed.

## ADDED Requirements

### Requirement: A multi-million-triangle Target renders within the frame budget
The system SHALL render a Target of at least five million triangles within the 60fps
frame budget on mesh-shader-capable hardware, measured from GPU timestamps on a real
device at the viewport's native resolution. The measurement SHALL be asserted, not
merely reported, and SHALL NOT be taken on the simulator, whose GPU timing is not
representative.

#### Scenario: Five million triangles hold the budget on device
- **WHEN** a Target of at least five million triangles is loaded and rendered on device
- **THEN** the average GPU frame time SHALL be within the 60fps budget
- **AND** rendering SHALL allocate no GPU buffers per frame

#### Scenario: The measurement is not silently skipped
- **WHEN** the acceptance measurement cannot run because no device is available
- **THEN** it SHALL skip with an explicit reason rather than report success

### Requirement: The render path is selected by measured need, not by capability alone
The system SHALL fall back to the indexed-vertex pipeline on the simulator and on
hardware without mesh-shader support, and MAY render the Target through a meshlet
pipeline where mesh shaders are supported. The choice of which pipeline the acceptance
budget is met with SHALL be recorded, so that a passing budget on the fallback path is
not mistaken for a meshlet pipeline being present.

#### Scenario: The fallback remains available everywhere
- **WHEN** the device does not support mesh shaders, or the code runs on the simulator
- **THEN** the Target SHALL render through the indexed-vertex pipeline

#### Scenario: The path that met the budget is identifiable
- **WHEN** the acceptance measurement passes
- **THEN** the render path it ran through SHALL be reported alongside the result

### Requirement: Performance claims rest on representative geometry
Frame-time acceptance for the Target SHALL be measured against geometry representative
of a scanned or sculpted asset, not solely against procedurally replicated uniform
topology, because uniform tiles give perfect cache locality and uniform triangle size
and so overstate throughput.

#### Scenario: A real asset backs the claim
- **WHEN** the acceptance measurement is taken
- **THEN** it SHALL include a run over geometry derived from a committed real asset
- **AND** where that run and a synthetic run disagree materially, the real asset's
  result SHALL be the one the acceptance is judged on

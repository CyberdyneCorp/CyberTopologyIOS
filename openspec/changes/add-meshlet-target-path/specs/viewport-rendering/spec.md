# viewport-rendering — Delta Spec (add-meshlet-target-path)

Closes the multi-million-triangle acceptance for the high-poly Target, and states
plainly that the pipeline choice is measurement-led rather than assumed.

## ADDED Requirements

### Requirement: A multi-million-triangle Target renders within the frame budget
The system SHALL render a multi-million-triangle Target within the 60fps frame budget on
mesh-shader-capable hardware, measured from GPU timestamps on a real device at the
viewport's native resolution, over geometry representative of a scanned asset. The
budget SHALL be judged on the WORST frame of a sustained run, not on the average alone,
because an average inside budget alongside a frame over it is a hitch the user can see.
The measurement SHALL be asserted, not merely reported, and SHALL NOT be taken on the
simulator, whose GPU timing is not representative.

Note on the threshold: the authoritative statement of this capability
(`docs/COMPETITOR_IDEAS.md`) says "multi-million-tri targets" without a figure, and the
traceability scenario is likewise "Multi-million-triangle target". Task 2.2a names 5M as
a concrete aim. An earlier draft of this delta hardened that aim into "at least five
million", which was stricter than the product actually requires; the verified figures
are recorded on the change's task 3.7 so "multi-million" is never left vague.

#### Scenario: A multi-million-triangle Target holds the budget on device
- **WHEN** a multi-million-triangle Target derived from a real asset is rendered on device
  at the viewport's native resolution
- **THEN** both the average AND the worst GPU frame time SHALL be within the 60fps budget
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

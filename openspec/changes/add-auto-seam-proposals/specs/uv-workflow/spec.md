# uv-workflow — Delta Spec (add-auto-seam-proposals)

## ADDED Requirements

### Requirement: Seam proposals respect what the artist authored
The system SHALL propose additional UV seams on request, and the proposal SHALL treat existing authored seams as boundaries it will not cut across, so it suggests where ELSE to cut rather than re-deciding the whole layout.

A proposal SHALL only ever ADD seams. It SHALL NOT suggest removing an authored seam, and
accepting one SHALL never delete a seam the artist drew.

#### Scenario: An authored seam is never removed by accepting a proposal
- **WHEN** seams are authored, a proposal is generated and accepted
- **THEN** every authored seam SHALL still be a seam

#### Scenario: The proposal is bounded by authored seams
- **WHEN** a closed loop of authored seams isolates a region and a proposal is generated
- **THEN** the proposal SHALL NOT contain seams that cut across that loop

### Requirement: A seam proposal is reviewed before it applies
A seam proposal SHALL be shown distinctly from authored seams and SHALL apply only when accepted. Discarding SHALL leave the document unchanged and journal nothing; accepting SHALL be a single undoable step.

#### Scenario: Discarding a proposal changes nothing
- **WHEN** a proposal is generated and discarded
- **THEN** the seam set SHALL be unchanged and the undo stack SHALL be unchanged

#### Scenario: Accepting a proposal is one undo step
- **WHEN** a proposal is accepted and the user undoes once
- **THEN** the seam set SHALL be exactly what it was before accepting

#### Scenario: A proposal is visually distinct from an authored seam
- **WHEN** a proposal is displayed
- **THEN** proposed seams SHALL be distinguishable from seams already authored

### Requirement: A proposal that finds nothing is a result, not a failure
Some cages need no further cuts — a planar cage grows into a single chart and has no internal chart boundaries at all. The system SHALL report that outcome as a statement about the mesh, and SHALL NOT phrase it as an inability to analyse the mesh.

#### Scenario: A cage needing no seams says so
- **WHEN** a proposal is requested for a cage that needs no further seams
- **THEN** the system SHALL state that no seams are needed, distinctly from stating that a proposal could not be produced

#### Scenario: No EditMesh is distinct from no seams needed
- **WHEN** a proposal is requested with no EditMesh in the document
- **THEN** the system SHALL say there is no EditMesh, and SHALL NOT report that the layout needs no seams

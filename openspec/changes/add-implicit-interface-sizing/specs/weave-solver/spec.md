# weave-solver — Delta Spec (add-implicit-interface-sizing)

Locks the sizing behaviour a region solve already has, so it cannot regress silently.

## ADDED Requirements

### Requirement: A region solve sizes itself from its prescribed interface
A region solve SHALL derive its quad budget from the region's own area and the spacing of the interface it must land on, so a solved patch matches the surrounding cage's scale without the caller supplying a density.

The derived budget SHALL override the caller's requested quad count for a region solve,
because a region inheriting a whole-mesh budget fights its own pinned interface. When no
interface spacing can be measured the solver SHALL decline to derive one and leave the
caller's parameters untouched, rather than fabricate a number.

#### Scenario: Sizing follows interface spacing rather than face count
- **WHEN** a region of unit area is solved whose boundary is subdivided at half-unit spacing
- **THEN** the derived budget SHALL reflect the area divided by the squared interface
  spacing, NOT the number of faces in the region

#### Scenario: Sizing is invariant under scale
- **WHEN** the same region is solved on a cage uniformly scaled down
- **THEN** the derived budget SHALL be unchanged, so no density dial is needed to
  compensate for the model's units

#### Scenario: A frozen patch re-derives the budget
- **WHEN** faces inside the region are frozen and the region is solved
- **THEN** the budget SHALL be derived from the remaining area and the interface that now
  includes the frozen patch's boundary
- **AND** the budget SHALL be smaller than the same region solved with nothing frozen

#### Scenario: The derived budget wins over a caller preset
- **WHEN** a region solve is given a quad budget far finer than its interface prescribes
- **THEN** the solved patch SHALL follow the prescription rather than the caller's budget

#### Scenario: An unmeasurable region declines rather than guessing
- **WHEN** a region has no measurable interface
- **THEN** the solver SHALL NOT derive a budget

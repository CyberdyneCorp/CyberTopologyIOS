# weave-solver — Delta Spec (add-region-external-reference)

Lets a region solve project onto the Target rather than onto the patch it is rewriting.

## ADDED Requirements

### Requirement: A region solve may project onto an external reference surface
A region solve SHALL accept an external reference surface and project its interior vertices onto that surface, so a patch grown from a coarse seed follows the Target's detail rather than the seed's approximation of it.

Supplying no external reference SHALL leave the solve byte-identical to projecting onto the
working mesh, so the capability cannot change existing output by merely existing. An external
reference SHALL NOT affect interface vertices, whose positions are already bitwise-guaranteed
and which are never smoothed.

#### Scenario: Detail finer than the seed band is followed
- **WHEN** a region is solved with the Target supplied as the external reference, over Target
  geometry with detail finer than the seed band
- **THEN** the solved interior vertices SHALL lie closer to the Target than the same solve
  projecting onto the working mesh

#### Scenario: No external reference is inert
- **WHEN** a region solve supplies no external reference
- **THEN** the result SHALL be byte-identical to the same solve before this capability existed

#### Scenario: The interface is unaffected
- **WHEN** a region is solved with an external reference
- **THEN** every interface vertex SHALL keep its id and bitwise position, exactly as the
  prescribed-boundary requirement demands

#### Scenario: An unusable external reference is refused, not silently ignored
- **WHEN** an external reference is supplied that cannot be projected onto
- **THEN** the solve SHALL refuse with a stated reason rather than fall back to the working
  mesh without saying so

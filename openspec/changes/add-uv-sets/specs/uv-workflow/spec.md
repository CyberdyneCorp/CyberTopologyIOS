# uv-workflow — Delta Spec (add-uv-sets)

## ADDED Requirements

### Requirement: Multiple named UV sets per mesh
A mesh SHALL support multiple named UV sets, exactly one of which is active. Every UV operation SHALL act on the active set, and SHALL require no knowledge that other sets exist.

Creating a set SHALL copy the active layout rather than producing an empty one, because an empty set
is indistinguishable downstream from a real layout collapsed at the origin. Creating a set SHALL
require an existing layout to copy.

The active set SHALL NOT be deletable, which would leave the mesh with no layout. Set names SHALL be
non-empty and SHALL NOT contain the reserved separator.

#### Scenario: Switching sets switches the layout
- **WHEN** a second UV set is created, edited, and activated
- **THEN** the mesh's UVs SHALL be that set's, and the previous set SHALL be preserved under its own name

#### Scenario: Other UV operations are unaffected
- **WHEN** any UV operation runs while a non-default set is active
- **THEN** it SHALL act on the active set

#### Scenario: The active set cannot be removed
- **WHEN** deletion of the active set is requested
- **THEN** it SHALL be refused and the mesh SHALL still have a UV layout

### Requirement: UV sets persist in the document with one source of truth per layout
UV sets beyond the active one SHALL persist in the document, since the object payload carries only one UV channel.

The persisted record SHALL store the active set's NAME but SHALL NOT store its layout: the payload
already carries that, and a second copy allows a stale one to overwrite newer edits.

Restoring the record SHALL NOT modify the active layout.

Rebuilding a mesh from its payload SHALL restore its UV sets, because a payload round trip otherwise
discards every set but the active one — and editing a mesh round-trips through its payload.

A record written for a different topology SHALL be refused, and the document SHALL still open.

Changing UV sets SHALL be undoable, and a change that also alters the active layout SHALL be a
SINGLE undo step covering both.

#### Scenario: Sets survive a save and load
- **WHEN** a document with two UV sets is saved and reopened
- **THEN** both sets SHALL be present and the same set SHALL be active

#### Scenario: A stale record cannot discard newer edits
- **WHEN** UVs are edited after the record was written, and that record is applied again
- **THEN** the edited layout SHALL be unchanged

#### Scenario: Editing a mesh preserves its other sets
- **WHEN** a mesh with two UV sets has its geometry or UVs edited
- **THEN** both sets SHALL still be present afterwards

#### Scenario: Switching sets is one undo
- **WHEN** the active set is switched and the user undoes once
- **THEN** both the layout and the active set SHALL be what they were

#### Scenario: A record for the wrong topology is ignored
- **WHEN** a document carries a UV-set record written for a different corner count
- **THEN** the document SHALL open and the payload's own layout SHALL be used

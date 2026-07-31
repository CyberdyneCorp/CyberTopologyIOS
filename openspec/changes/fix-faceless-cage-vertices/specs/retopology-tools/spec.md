# Delta: retopology-tools (fix-faceless-cage-vertices)

## ADDED Requirements

### Requirement: A solved cage contains no face-less vertices

A whole-mesh auto-retopology solve SHALL return a cage in which every vertex belongs to at
least one face, and SHALL preserve every face and every kept vertex's exact position while
doing so.

Rationale: measured, a 1108-face cage came back carrying 1186 vertices, 91 of them in no face
at all and 41% of those in the ears. Relax builds a vertex's one-ring from its edges, so it
skips such a vertex silently — 130 relax passes over an ear tip moved zero of the 15 vertices
under the brush, while the same relax unmasked moved 1084 of 1186. They are also
un-editable, they inflate the vertex count the artist reads, and a payload round trip
preserves them, so no later step cleans up.

#### Scenario: A solved cage
- **WHEN** a whole-mesh solve returns a cage
- **THEN** no vertex of that cage SHALL be without a face

#### Scenario: Nothing else changes
- **WHEN** face-less vertices are dropped from a cage
- **THEN** every face SHALL survive and every kept vertex SHALL keep its exact position and
  its sharing with neighbouring faces

#### Scenario: A region patch keeps its reported ids
- **WHEN** a prescribed-boundary region solve reports interface vertices
- **THEN** those ids SHALL still name the vertices they described

### Requirement: A relax that changes nothing says so

When a relax stroke completes without changing the cage, the system SHALL tell the artist,
naming why a vertex can be immovable.

Rationale: Relax slides vertices along the surface toward their one-ring centroid, so two
kinds of vertex cannot move by construction — one with no faces, and one whose correction
points along its own normal, which is every vertex at a tip. Reported from device as "why
can't I Relax this part of the bunny ears?": the stroke ran, journaled nothing, and said
nothing, so the tool looked broken and the artist kept trying in the one place it could
never work.

#### Scenario: Nothing moved
- **WHEN** a relax stroke ends having changed no vertex
- **THEN** the system SHALL report that it changed nothing and why

#### Scenario: A relax that worked
- **WHEN** a relax stroke smooths the cage
- **THEN** no such notice SHALL appear

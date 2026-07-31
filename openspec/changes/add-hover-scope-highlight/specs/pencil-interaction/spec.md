# Delta: pencil-interaction (add-hover-scope-highlight)

## ADDED Requirements

### Requirement: Hovering previews the element a drag would grab

While hovering over the EditMesh, the system SHALL highlight the element a Move drag started at
that point would carry — the vertex, the edge loop, or the face — and SHALL clear the highlight
when the hover ends.

The element SHALL be resolved by the SAME rule the drag uses to decide its scope. A highlight
resolved by its own thresholds would claim one element while the drag took another, teaching a
rule the tool does not follow.

Rationale: the scope turns on distances as small as a fraction of a cell, and the drag names it
only once it is already live. Hovering is the moment before commitment.

#### Scenario: A hovered vertex
- **WHEN** the pointer hovers within the drag's vertex window of a vertex
- **THEN** that vertex SHALL be highlighted

#### Scenario: A hovered edge
- **WHEN** the pointer hovers within the drag's edge window of an edge
- **THEN** the whole loop that a drag would carry SHALL be highlighted

#### Scenario: A hovered face
- **WHEN** the pointer hovers over the interior of a face, away from its vertices and edges
- **THEN** that face SHALL be highlighted

#### Scenario: The highlight agrees with the drag
- **WHEN** a point resolves to a given scope for a Move drag
- **THEN** hovering the same point SHALL highlight the element of that same scope

#### Scenario: The highlight clears
- **WHEN** the hover ends
- **THEN** no hover highlight SHALL remain

### Requirement: Each scope has its own colour and form

The hover highlight SHALL distinguish the three scopes by colour: a vertex in YELLOW, an edge
loop in RED, and a face in PINK.

A face SHALL be drawn as a translucent FILL and a loop as line segments, so the two are
distinguished by form as well as by hue.

Rationale: red and pink are the pair most easily confused, and colour alone would separate them
for only some readers. A broad low-alpha fill and a thin bright line are never mistaken for one
another.

#### Scenario: A face reads as a filled region
- **WHEN** a face is highlighted
- **THEN** its interior SHALL be filled, not merely outlined

#### Scenario: The fill does not pulse
- **WHEN** a face highlight is shown
- **THEN** its opacity SHALL be constant, unlike the create-hint ghost

### Requirement: A boundary edge is previewed like any other

Hovering an edge on the mesh boundary SHALL highlight what a drag would carry there, rather than
showing nothing.

Rationale: the preview answers "what is under the pointer", and a drag does move a boundary
edge — falling back to that edge's own vertices when its loop cannot be walked. Staying silent
would make the preview lie by omission exactly where the artist is aiming carefully. Whether a
double-tap may SLIDE such an edge is a separate rule, unchanged by this.

#### Scenario: Hovering a boundary edge
- **WHEN** the pointer hovers over a boundary edge
- **THEN** the vertices a drag would carry SHALL be highlighted

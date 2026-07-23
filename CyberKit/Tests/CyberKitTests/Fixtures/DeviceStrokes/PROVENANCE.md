# Device stroke corpus

Real Pencil strokes captured on-device with the DEBUG stroke recorder
(⚙ ▸ Debug ▸ "Record last stroke"), for the `simplify-gesture-grammar`
change (task 1.1).

These are distinct from `Fixtures/Strokes/`, which is a **synthetic** corpus:
every file there matches a code generator (`StrokeGestureCorpus`) and is
asserted to replay to its `expectedOutcome`. These strokes are **captured**,
not generated — they cannot be reproduced from code, and they currently
resolve to the WRONG outcome. That is the point: the gesture re-tune failed
twice against synthetic strokes (a programmatic square is either perfectly
closed or a perfect square wave, and neither resembles a hand on a Pencil),
so the re-tune must be driven by strokes that actually occur.

## The strokes

Device: iPad · Target: `seed-target` · captured 2026-07-22.

All four were drawn as quads adjacent to a central quad — one per side — each
a "U" of three sides with the fourth side (the edge shared with the central
quad) left open. Every one was **intended** as `createQuad`. Every one is
**recognized** as `shape=unknown conf=0.30; none:0.20` — the classifier's
only path to `createQuad` is inside its closed-shape branch, and an open U
never enters it.

| file | side | samples |
|------|------|---------|
| `quad_adjacent_top_pencil`    | top    | 285 |
| `quad_adjacent_right_pencil`  | right  | 299 |
| `quad_adjacent_bottom_pencil` | bottom | 281 |
| `quad_adjacent_left_pencil`   | left   | 331 |

## Acceptance

`DeviceStrokeCorpusTests` asserts each resolves to `createQuad` through the
real engine recognizer. Today those assertions fail and are wrapped in
`withKnownIssue` — the suite stays green while the bug is documented. When the
classifier re-tune (task 3) lands, the known issues resolve, Swift Testing
flags them as unexpectedly passing, and the wrappers come off. That is the
mechanical acceptance criterion the proposal calls for.

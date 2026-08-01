# Tasks: fix-halve-one-direction

- [x] 1.1 Judge each direction on its own; refuse only when neither can be halved.
- [x] 1.2 Report `directionsHalved`, and say so in the status line when it is one.
- [x] 1.3 Replace the accidental odd-span guard with the RECTANGLE invariant: the two spans
      must multiply to the face count.
- [x] 2.1 The reported cage — 5 x 6, 30 faces, 42 vertices — halves to 15, stays quad-only,
      and moves no vertex.
- [x] 2.2 Both directions odd is still refused, with the cage untouched.
- [x] 2.3 The L-shaped cage is still refused, now as irregular rather than by luck.
- [x] 1.4 REPORTED FROM DEVICE: a cage of two patches declined while blaming a pole that
      was not there. `notRectangular` is now its own refusal, because the artist's next move
      differs — a pole must be retopologized away, a second patch merely halved on its own.
- [x] 2.4 Two separate patches are refused as not-a-rectangle.
- [x] 2.5 END TO END through the real command path: a scoped Relax All moves the selected
      patch and NOT the other one; unscoped still reaches everything; and the selection
      survives the syncs that come with opening the panel.
- [x] 3.1 Run the mirrored suites on the iPad.

# Tasks: fix-halve-one-direction

- [x] 1.1 Judge each direction on its own; refuse only when neither can be halved.
- [x] 1.2 Report `directionsHalved`, and say so in the status line when it is one.
- [x] 1.3 Replace the accidental odd-span guard with the RECTANGLE invariant: the two spans
      must multiply to the face count.
- [x] 2.1 The reported cage — 5 x 6, 30 faces, 42 vertices — halves to 15, stays quad-only,
      and moves no vertex.
- [x] 2.2 Both directions odd is still refused, with the cage untouched.
- [x] 2.3 The L-shaped cage is still refused, now as irregular rather than by luck.
- [ ] 3.1 Run the mirrored suites on the iPad. BLOCKED: the device's signing identity has
      expired ("missing Xcode-Token"), so the test runner cannot be installed.

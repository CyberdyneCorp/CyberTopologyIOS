# add-weave-density-radial-symmetry

The two sub-gaps 5.2a split out (its task 5.3): a real density BRUSH, and RADIAL symmetry in the solver. Records the density decision made in 5.2a — per-vertex scale multipliers, because `isotropic.cpp` already sizes every edge against a per-vertex `kScaleAttribute` array, so the consumer exists and only an author-supplied source is missing. Radial is separate because its working domain is an angular sector, not an intersection of half-spaces, so it cannot reuse the multi-axis clip that landed in 5.2a.

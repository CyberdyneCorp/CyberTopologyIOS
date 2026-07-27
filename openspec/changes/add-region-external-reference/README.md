# add-region-external-reference

Phase 5's 5.4b: a region solve currently builds its reference surface from the mesh it is rewriting, so a Weave Fill refines its seed band and reprojects onto that approximation rather than onto the Target — losing any Target detail finer than the band. Spike-gated, because the deviation was already measured at 0.031 quads on a smooth fixture: task 0 decides whether that generalises (close the item) or was an artifact of the fixture (proceed), and measures what a Target-wide BVH costs before anything is designed around it.

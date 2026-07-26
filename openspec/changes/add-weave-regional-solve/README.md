# add-weave-regional-solve

Lift the Weave solver's whole-mesh-only restriction and land the prescribed-boundary interface guarantee (tasks 5.1a + 5.3): solve a face sub-region in place against frozen surrounding topology, with interface vertices bitwise-preserved and singularities forced interior — enforced by a hard conformance gate that refuses rather than publishes a violating ghost.

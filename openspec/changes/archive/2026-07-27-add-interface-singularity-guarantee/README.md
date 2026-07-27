# add-interface-singularity-guarantee

Turn the second half of Weave's prescribed-boundary claim into a guarantee: no singularity on the interface, enforced by refusing rather than reported as a count. Three earlier attempts failed by trying to control the number of merges AT an interface vertex; this one forces that number to zero (by feature-locking interface-adjacent edges) and instead normalises the triangle fan to the prescribed valence — turning a coupled global problem into a local one. Spike-gated, because it can still fail.

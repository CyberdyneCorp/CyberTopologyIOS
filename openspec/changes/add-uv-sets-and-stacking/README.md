# add-uv-sets-and-stacking

Phase 6's 6.7, first slice: symmetry-aware island stacking and UDIM tiles. Both land without any document-model change, because a UDIM tile assignment is DERIVED from the UVs rather than stored — a tile IS a region of UV space. Multiple UV SETS is split out as 6.7a: the document payload is OBJ, which carries exactly one UV channel, so more than one set needs sidecar persistence plus transaction integration.

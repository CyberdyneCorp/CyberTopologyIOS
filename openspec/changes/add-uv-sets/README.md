# add-uv-sets

Phase 6's 6.7a: multiple named UV sets per mesh, persisted in a document sidecar. The active set stays under the ordinary UV attribute, so the entire UV module is untouched and cannot read the wrong set. Two real defects found by testing: every mesh edit round-trips through the OBJ payload and was destroying stored sets, and storing the active set's data in the sidecar let a stale copy overwrite newer edits.

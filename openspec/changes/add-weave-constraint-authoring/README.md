# add-weave-constraint-authoring

Phase 5's 5.2a. `WeaveConstraints` stores all six constraint kinds but only three are honoured; this change makes pins and tagged loops real (they are already authored, persisted and rendered — nothing bridges them into a solve) and makes frozen faces authorable (the solver half is already done). The density brush and radial symmetry are gated on a type decision and may split out as 5.2b rather than be forced in.

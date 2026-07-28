# add-uv-stage-foundation

Phase 6's entry point, scoped as a vertical slice. The stage picker already exists and already journals `setStage` — but nothing branches on `.uv`, so the UV stage is stored and empty. And the engine can unwrap (`cyber_uv_atlas`) yet UVs cannot be READ back: there is no pointer view, no render-cache field, no accessor. That is the gate — a 2D UV view is impossible today regardless of how the UI is written, and every remaining Phase 6 task depends on it. So: UV readback, the stage branching to a real workspace, and a one-tap unwrap that reports what it produced.

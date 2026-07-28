# add-uv-on-surface-transform

Phase 6's 6.3b, first slice: the on-surface (UV3D) island UV transform, driven by the camera. It needed NO new input arbitration — `InputArbiter.cameraFeedsArmedTool` already exists for exactly this class of tool and already owns the verdict, correcting my earlier claim. The "live texture feedback" half is split out as 6.3c: nothing in the app samples a texture, so it needs a new render path rather than wiring.

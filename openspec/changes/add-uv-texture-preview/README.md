# add-uv-texture-preview

Phase 6's 6.3c: the first textured render path in the app — a procedural UV checker on the 3D surface, so a layout can be judged on the model. Corner-expanded vertices, because UVs are per-corner and a vertex-indexed stream would weld every seam shut. The offscreen test took three attempts: the first two passed against a deliberately broken shader, and mutations exposed both.

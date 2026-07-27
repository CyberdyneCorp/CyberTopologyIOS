# add-implicit-interface-sizing

Phase 5's 5.5a: a region solve sizes itself from the boundary it must land on, so an auto-filled patch matches the surrounding cage with no density dial. Measured rather than assumed — it already works, having emerged from 5.2a's frozen-face subtraction meeting a spacing-based derivation. No behaviour change; this adds the spec requirement and the tests that stop an accidental property from leaving silently, including the one fixture a uniform grid cannot provide.

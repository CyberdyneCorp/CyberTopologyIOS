# Tasks: add-implicit-interface-sizing (5.5a)

No behaviour change. The mechanism already works; this pins it down so it cannot leave
silently, and corrects the record that called it blocked.

## 0. Measure before building

- [x] 0.1 Spike `prescribedQuadBudget` across region, frozen-subset, and scale variations
      rather than assuming work remained. Result: implicit sizing ALREADY works — a frozen
      2x2 inside a 4x4 block yields 12, and the same block at half spacing yields the same
      16.
- [x] 0.2 **Find the case a uniform grid cannot distinguish.** On any uniform grid
      `area / spacing²` equals the face count, so every grid fixture passes equally against
      an implementation that just counts faces. One square face with an 8-edge subdivided
      boundary separates them: budget 4, face count 1. Without this the whole suite would
      have been vacuous.

## 1. Lock the properties

- [x] 1.1 Budget follows interface SPACING, not face count (the octagon case).
- [x] 1.2 Budget is SCALE-INVARIANT — this is what "no dials" means.
- [x] 1.3 A frozen patch re-derives the budget from the interface it adds.
- [x] 1.4 The derived budget OVERRIDES the caller's preset. This failure already shipped
      once in reverse (a region inheriting the whole-mesh 50 000-quad default welded an
      over-fine patch onto a coarse cage), so it is asserted, not trusted.
- [x] 1.5 An unmeasurable region returns nil rather than a fabricated budget.

## 2. Record and validate

- [x] 2.1 Spec delta stating the requirement, so a refactor that swaps the derivation for a
      face count fails a test instead of shipping.
- [x] 2.2 Share the suite into the app-hosted target so it runs on device too.
- [x] 2.3 `openspec validate --changes --strict`; full simulator suite; engine suite; device
      run of the new suite.
- [x] 2.4 Update the master 5.5a entry: it was recorded as blocked and is in fact satisfied,
      with the reason (it emerged from 5.2a's frozen subtraction meeting an already
      spacing-based derivation) rather than claiming it was built here.

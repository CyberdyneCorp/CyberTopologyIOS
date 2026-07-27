# Tasks: add-region-external-reference (5.4b)

> **Task 0 OUTCOME: PROCEED.** The filed 0.031-quad deviation did not generalise — it is
> 0.145 mean / 0.351 max on smooth geometry and **0.419 mean / 1.257 max on rippled**, i.e.
> the worst interior vertex sits over a full quad edge off the surface. BVH build is ~636 µs
> per 1k faces, so ~3.0 s at 4.8M faces, which makes caching mandatory rather than optional
> because a fill runs synchronously on the main actor. Numbers: `spike/RESULTS.md`.

## 0. Spike: is the defect real, and what does fixing it cost?

- [x] 0.1 Build a Target with genuine high-frequency detail — the 0.031-quad figure came
      from a SMOOTH fixture, where a coarse seed band approximates the Target well by
      construction and therefore cannot exhibit the failure mode at all.
- [x] 0.2 Measure interior deviation from the Target for a region solve projecting onto (a)
      the working mesh, as today, and (b) the Target itself. Report mean and MAX: a mean
      that stays small while the max blows up is the signature of exactly the lost-detail
      case this change is about, and a mean-only measurement would hide it.
- [x] 0.3 Measure the COST: `ReferenceSurface` build time over a multi-million-triangle
      Target. A fill is interactive today because the working mesh is small; if this lands
      per-fill the feature stops being interactive.
- [x] 0.4 **Decision gate.** If the deviation on detailed geometry is still imperceptible,
      CLOSE 5.4b as measured-and-not-worth-it rather than leaving it open as vague quality
      debt — and record the number so nobody re-opens it on a hunch. If it is real, proceed,
      and let 0.3 decide whether caching is required in this change or can wait.

## 1. Engine (patch 0008), only if 0.4 says proceed

- [ ] 1.1 Region path accepts an external `ReferenceSurface` instead of always constructing
      one from the working mesh. Absent ⇒ today's behaviour exactly.
- [ ] 1.2 Interface vertices stay untouched — they are never smoothed (Invariant P), so this
      should fall out, and a test must prove it did.
- [ ] 1.3 An unusable reference is refused with a reason, never a silent fallback to the
      working mesh. A silent fallback would make the feature untestable from outside.
- [ ] 1.4 Fold into the patch stack as a numbered patch, per the engine's discipline. Do NOT
      leave raw submodule edits: `build_engine.sh` refuses a tree the patch stack does not
      fit, which is the correct behaviour and not to be worked around.

## 2. C API and CyberKit

- [ ] 2.1 Entry point carrying the reference by mesh handle, riding the handle like
      `cyber_mesh_set_solve_region` — established pattern, cleared after the solve.
- [ ] 2.2 `Mesh.remeshedRegion` gains the parameter; `RegionWeaveSolver` passes the Target.
- [ ] 2.3 Caching keyed on the reference handle. **MANDATORY, not conditional** — 0.3
      measured ~3.0 s of BVH build at 4.8M faces, and a fill runs synchronously on the main
      actor, so an uncached build would freeze the UI for seconds on every fill.

## 3. App

- [ ] 3.1 `WeaveFillSession` supplies the Target. It already resolves and caches a
      `SurfaceSnapper` over it, so the Target handle is in hand — but note the snapper and
      the engine's `ReferenceSurface` are different types over the same geometry, and
      building both per fill would pay the BVH cost twice.

## 4. Tests

- [ ] 4.1 Detail finer than the seed band is followed: interior vertices land closer to the
      Target than with the working-mesh reference. Asserted against the measurement from 0.2,
      not against a guessed threshold.
- [ ] 4.2 **No external reference is byte-identical** to before — the inertness property.
- [ ] 4.3 Interface vertices keep ids and bitwise positions with a reference supplied.
- [ ] 4.4 An unusable reference refuses.
- [ ] 4.5 Whole-mesh solves unchanged; no interface golden regenerated.

## 5. Close out

- [ ] 5.1 `openspec validate --changes --strict`; simulator; engine host suite; device run.
- [ ] 5.2 Update the master 5.4b entry with the measured before/after, and state plainly that
      the no-cage-boundary half is NOT included and still needs the carve path.

# Task 0 results — the hypothesis is REFUTED

Reproduce: build the engine host tests (`Scripts/build_engine.sh --host-tests`), then

```
clang++ -std=c++20 -O2 \
  -IEngine/CyberRemesherAndUV/src/{core,quadrangulate,retopo,accel}/include \
  interface_lock_spike.cpp \
  Engine/build/engine-host-tests/src/{core,quadrangulate,retopo,accel}/libcyber_*.a -o spike
```

The spike deliberately links the built libs rather than adding a test to the submodule:
the engine enforces a patch-stack discipline, and an unproven idea has no business
entering it.

## Measured

`irr` = irregular interface vertices, `triIface` = non-quads touching the interface,
`q`/`t` = quad/triangle faces in the solved region.

```
---- density 1x ----
grid66_center  iface=16 | BASE irr= 3 triIface= 0 q= 20 t=  0 | LOCKED irr=14 triIface=19 q= 10 t= 20
lshape         iface=14 | BASE irr= 0 triIface= 0 q=  6 t=  0 | LOCKED irr=12 triIface=12 q=  0 t= 12
cross          iface=12 | BASE irr= 0 triIface= 0 q=  5 t=  0 | LOCKED irr= 8 triIface=10 q=  0 t= 10
sphere_cap     iface=16 | BASE irr= 0 triIface= 0 q= 16 t=  0 | LOCKED irr=14 triIface=20 q=  8 t= 20
---- density 4x ----
grid66_center  iface=16 | BASE irr=16 triIface= 7 q=356 t= 38 | LOCKED irr=16 triIface=43 q=343 t= 68
lshape         iface=14 | BASE irr= 0 triIface= 0 q=  6 t=  0 | LOCKED irr=12 triIface=12 q=  0 t= 12
cross          iface=12 | BASE irr= 0 triIface= 0 q=  5 t=  0 | LOCKED irr= 8 triIface=10 q=  0 t= 10
sphere_cap     iface=16 | BASE irr=16 triIface= 8 q=296 t= 30 | LOCKED irr=16 triIface=43 q=281 t= 60
```

Exact landing survived locking in every case, which is the one thing that had to hold.

## Task 0.1: the mechanism WORKS — that is not the problem

Locking did force `k(b) = 0`: on `lshape` and `cross` the solved region goes to **zero
quads**, every face a triangle, so no merge crossed a locked edge. The mechanism did
exactly what the proposal predicted.

## Task 0.4: the falsifier fires

Locking **never improves** irregularity. It is neutral at best (16 → 16 at 4x) and
catastrophic otherwise (0 → 12 on `lshape`, 0 → 14 on `sphere_cap`, 3 → 14 on
`grid66_center`). Not one fixture at one density got better.

**Why the decomposition was wrong.** `q_in(b)` counts the faces the surrounding CAGE
expects — quads. Forcing `k(b) = 0` guarantees every region face at `b` is a TRIANGLE, so
`faces(b) = n(b)`, the raw triangle fan the isotropic stage left, typically 5-6 against a
prescription of 2-3. Conformance therefore requires collapsing every interface fan to
2-3 triangles. That is not a local edge flip away; it is a large topological change, and
the fan normalisation of task 0.3 cannot deliver it. Setting `k(b) = 0` does not simplify
the problem — it replaces a coupled-but-satisfiable constraint with an unsatisfiable local
one, and it does so at every interface vertex simultaneously.

## Task 0.5: the cost is independently disqualifying

Even if conformance had improved, the price would not be payable. `triIface` rises from 0
to 12-20 at 1x and from 7-8 to 43 at 4x, and `lshape`/`cross` lose **every** quad in the
solved region. A prescribed-boundary solver whose seam is a ring of triangles is not a quad
retopology tool. Task 0.5 existed to catch exactly this, and it did.

## Consequences

- Tasks 1-4 are NOT started. This is the fourth refuted attempt at 5.3a.
- The L-shape counterweight test STAYS. Task 4.2 would have deleted it on success; the
  guarantee does not hold, so removing it would assert something false.
- 5.7's do-not-claim note STAYS: "Weave places no singularity on a prescribed interface"
  remains unsupported, and Table 2 of the benchmark stays ungated.
- The fallbacks (boundary-staircase lattice, or a real b-matching solver) are NOT started
  speculatively, per the task 0.4 instruction.

## Caveat on the baselines

The absolute baselines here do not reproduce the committed "lshape 5 of 16 irregular"
figure: this spike sizes by 1x/4x of mean edge length, while the shipped path derives
density from `prescribedQuadBudget`, and the L/cross regions are constructed here rather
than loaded from the committed fixtures. That does not affect the conclusion, which rests
on the BASE-vs-LOCKED delta measured under identical conditions — but it does mean these
numbers should not be quoted as the fixtures' conformance figures.

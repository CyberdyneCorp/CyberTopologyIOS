# Task-0 falsification spike (2026-07-26)

Reproduction material for the negative result recorded in `../tasks.md` §0 and
`../design.md` ADDENDUM. The engine tree was reverted afterwards — nothing here is
applied. Kept because a negative result nobody can re-run is a rumour.

- `spike-results.txt` — raw measured output, all fixtures and configurations.
- `test_region_solve_spike.cpp` — the harness (drop in `tests/core/`, add to
  `tests/CMakeLists.txt`). Includes the minimal `pairInterfaceRingFirst` that failed
  to move the number.
- `region_solve.hpp` — the spike mask pair (drop in `src/core/include/cyber/core/`).
- `spike-splitpass-guard.diff` — the 4-line SplitPass guard plus its
  `IsotropicOptions` field. This part PASSED and is validated for task 3.

Re-run:

    cmake -S . -B build-spike -G Ninja -DCMAKE_BUILD_TYPE=Release \
          -DCYBER_BUILD_TESTS=ON -DCYBER_BUILD_CLI=OFF
    cmake --build build-spike --target cyber_tests -j 6
    ./build-spike/tests/cyber_tests --test-case="region-solve spike*"

(`scripts/build_engine.sh` sets `CYBER_BUILD_TESTS=OFF`, so engine tests need this
separate host configure — see tasks.md 9.4.)

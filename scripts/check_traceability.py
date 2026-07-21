#!/usr/bin/env python3
"""Spec-scenario traceability check (design D9, spec: quality-assurance).

Parses every '#### Scenario:' heading from the change's capability specs and
compares them against tests/traceability.yaml. Fails (exit 1) when:

  * a spec scenario is neither mapped to at least one test nor listed under
    the explicit 'pending:' allowlist,
  * a mapped scenario has an empty test list,
  * a scenario appears both mapped and pending,
  * the yaml references a scenario that no longer exists in the specs
    (stale entries keep the map honest).

The pending allowlist keeps CI green during bootstrap while making the
untested-scenario debt visible; it must only shrink as tasks land.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SPECS_DIR = REPO_ROOT / "openspec/changes/add-cybertopology-app/specs"
DEFAULT_MAP = REPO_ROOT / "tests/traceability.yaml"
SCENARIO_RE = re.compile(r"^####\s+Scenario:\s*(.+?)\s*$")


def parse_spec_scenarios(specs_dir: Path) -> dict[str, set[str]]:
    """Return {capability: {scenario name, ...}} from specs/*/spec.md."""
    scenarios: dict[str, set[str]] = {}
    for spec in sorted(specs_dir.glob("*/spec.md")):
        capability = spec.parent.name
        for line in spec.read_text(encoding="utf-8").splitlines():
            match = SCENARIO_RE.match(line)
            if match:
                scenarios.setdefault(capability, set()).add(match.group(1))
    return scenarios


def load_traceability(map_path: Path) -> tuple[dict[str, dict[str, list[str]]], dict[str, set[str]]]:
    """Return (mapped, pending) from the traceability yaml."""
    import yaml  # deferred: give a clear error where it is actually needed

    data = yaml.safe_load(map_path.read_text(encoding="utf-8")) or {}
    mapped_raw = data.get("scenarios") or {}
    pending_raw = data.get("pending") or {}
    mapped = {
        capability: {name: list(tests or []) for name, tests in (entries or {}).items()}
        for capability, entries in mapped_raw.items()
    }
    pending = {
        capability: set(names or []) for capability, names in pending_raw.items()
    }
    return mapped, pending


def check(
    spec_scenarios: dict[str, set[str]],
    mapped: dict[str, dict[str, list[str]]],
    pending: dict[str, set[str]],
) -> list[str]:
    """Return a list of problem descriptions (empty means the map is clean)."""
    problems: list[str] = []

    for capability, names in sorted(spec_scenarios.items()):
        for name in sorted(names):
            tests = mapped.get(capability, {}).get(name)
            is_pending = name in pending.get(capability, set())
            if tests and is_pending:
                problems.append(
                    f"{capability} / {name}: both mapped and pending — remove it from 'pending:'"
                )
            elif tests is not None and not tests:
                problems.append(
                    f"{capability} / {name}: mapped with an empty test list"
                )
            elif tests is None and not is_pending:
                problems.append(
                    f"{capability} / {name}: UNMAPPED — add tests under 'scenarios:' "
                    f"or allowlist it under 'pending:'"
                )

    for capability, entries in sorted(mapped.items()):
        for name in sorted(entries):
            if name not in spec_scenarios.get(capability, set()):
                problems.append(
                    f"{capability} / {name}: mapped in yaml but not found in any spec (stale?)"
                )
    for capability, names in sorted(pending.items()):
        for name in sorted(names):
            if name not in spec_scenarios.get(capability, set()):
                problems.append(
                    f"{capability} / {name}: pending in yaml but not found in any spec (stale?)"
                )

    return problems


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--specs-dir", type=Path, default=DEFAULT_SPECS_DIR)
    parser.add_argument("--map", dest="map_path", type=Path, default=DEFAULT_MAP)
    args = parser.parse_args(argv)

    spec_scenarios = parse_spec_scenarios(args.specs_dir)
    if not spec_scenarios:
        print(f"check_traceability: no scenarios found under {args.specs_dir}", file=sys.stderr)
        return 1
    mapped, pending = load_traceability(args.map_path)

    problems = check(spec_scenarios, mapped, pending)

    total = sum(len(v) for v in spec_scenarios.values())
    mapped_count = sum(
        1
        for capability, entries in mapped.items()
        for name in entries
        if name in spec_scenarios.get(capability, set())
    )
    pending_count = sum(
        1
        for capability, names in pending.items()
        for name in names
        if name in spec_scenarios.get(capability, set())
    )
    print(
        f"check_traceability: {total} spec scenario(s): "
        f"{mapped_count} mapped, {pending_count} pending"
    )

    if problems:
        print(f"check_traceability: {len(problems)} problem(s):", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1

    print("check_traceability: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env bash
#
# Coverage gate (design D9, spec: quality-assurance).
#
# Runs the test suite with code coverage enabled, extracts per-layer line
# coverage from the .xcresult via `xcrun xccov` (layers are source-path
# prefixes, not binaries — static libraries have no binary of their own),
# and fails (exit 1) if any gated layer is at or below COVERAGE_MIN percent.
#
# Bootstrap rule: until real feature code exists, the gate must not fail
# vacuously. The gated figure is therefore computed over *covered source
# files* (files with at least one covered line); files never touched by any
# test are listed loudly but excluded from the denominator. Once the shell
# and CyberKit carry real code, tighten by moving targets to STRICT_TARGETS.
#
# Environment overrides:
#   COVERAGE_MIN   minimum required line coverage percent (default: 90)
#   DESTINATION    xcodebuild -destination (default: first available iPad simulator)
#   RESULT_BUNDLE  .xcresult path; if it already exists it is gated as-is
#                  (skips the test run), otherwise tests run writing into it
#                  (default: fresh temp path)
#   PROJECT        Xcode project path      (default: CyberTopology.xcodeproj)
#   SCHEME         scheme to test          (default: CyberTopology)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

COVERAGE_MIN="${COVERAGE_MIN:-90}"
PROJECT="${PROJECT:-CyberTopology.xcodeproj}"
SCHEME="${SCHEME:-CyberTopology}"
RESULT_BUNDLE="${RESULT_BUNDLE:-}"

# Layers gated by this script, as `name:path-prefix` pairs (design D9: per
# layer, not per binary — CyberKit is a static library, so xccov attributes
# its lines to whichever binary linked it, never to a "CyberKit" target).
# The engine repo carries its own suite and is never gated here.
GATE_LAYERS="app-shell:App/Sources CyberKit:CyberKit/Sources"

if [[ -z "${DESTINATION:-}" ]]; then
    # First iPad on the NEWEST runtime that satisfies the deployment target
    # (18+). Older-runtime simulators are listed as available but rejected by
    # xcodebuild; runtimes older than the selected Xcode's are also prone to
    # testmanagerd socket failures.
    UDID="$(xcrun simctl list devices available | awk '
        /^-- iOS ([0-9]+)/ {
            split($3, v, "."); ver = v[1] * 100 + v[2]
            runtime_ok = (v[1] >= 18); taken = 0; next
        }
        /^--/ { runtime_ok = 0; next }
        runtime_ok && !taken && /iPad/ {
            if (match($0, /[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}/)) {
                if (ver > best_ver) { best_ver = ver; best = substr($0, RSTART, RLENGTH) }
                taken = 1
            }
        }
        END { if (best != "") print best }')"
    if [[ -z "$UDID" ]]; then
        echo "coverage_gate: no available iPad simulator on iOS 18+ found" >&2
        exit 1
    fi
    DESTINATION="platform=iOS Simulator,id=${UDID}"
fi

if [[ -z "$RESULT_BUNDLE" ]]; then
    RESULT_BUNDLE="$(mktemp -d)/coverage_gate.xcresult"
fi

if [[ -e "$RESULT_BUNDLE" ]]; then
    echo "coverage_gate: reusing result bundle at ${RESULT_BUNDLE}"
else
    echo "coverage_gate: running tests (destination: ${DESTINATION})"
    echo "coverage_gate: result bundle: ${RESULT_BUNDLE}"
    xcodebuild test \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -destination "$DESTINATION" \
        -enableCodeCoverage YES \
        -resultBundlePath "$RESULT_BUNDLE" \
        CODE_SIGNING_ALLOWED=NO
fi

echo "coverage_gate: extracting coverage from ${RESULT_BUNDLE}"
REPORT_JSON="$(mktemp -t coverage_gate_report).json"
xcrun xccov view --report --json "$RESULT_BUNDLE" > "$REPORT_JSON"

GATE_LAYERS="$GATE_LAYERS" COVERAGE_MIN="$COVERAGE_MIN" REPO_ROOT="$REPO_ROOT" \
    python3 - "$REPORT_JSON" <<'PY'
import json
import os
import sys

report = json.load(open(sys.argv[1]))
layers = [entry.split(":", 1) for entry in os.environ["GATE_LAYERS"].split()]
minimum = float(os.environ["COVERAGE_MIN"])
repo_root = os.environ["REPO_ROOT"]
failed = False

# A source file can appear under several binaries (app, test bundles) when
# statically linked; keep the best-covered instance per path. Test sources
# themselves are never gated.
files_by_path = {}
for target in report.get("targets", []):
    for f in target.get("files", []):
        path = f.get("path", "")
        best = files_by_path.get(path)
        if best is None or f.get("coveredLines", 0) > best.get("coveredLines", 0):
            files_by_path[path] = f

for name, prefix in layers:
    prefix_abs = os.path.join(repo_root, prefix) + os.sep
    files = [f for p, f in files_by_path.items() if p.startswith(prefix_abs)]
    if not files:
        print(f"FAIL [{name}] no source files under {prefix} in the coverage "
              f"report; is the layer built and its tests running?")
        failed = True
        continue

    covered_files = [f for f in files if f.get("coveredLines", 0) > 0]
    untouched = [f for f in files if f.get("coveredLines", 0) == 0]

    for f in sorted(files, key=lambda f: f.get("lineCoverage", 0.0)):
        print(f"    {f.get('lineCoverage', 0.0) * 100.0:6.1f}%  "
              f"{f.get('coveredLines', 0)}/{f.get('executableLines', 0)} lines  "
              f"{f.get('name')}")
    if untouched:
        print(f"[{name}] BOOTSTRAP: {len(untouched)} file(s) with zero coverage "
              f"excluded from the gated denominator (see list above)")

    if not covered_files:
        # Nothing exercised at all: vacuous, warn loudly but do not fail.
        print(f"WARN [{name}] no covered source files yet; gate is vacuous "
              f"until real feature code and tests exist")
        continue

    executable = sum(f["executableLines"] for f in covered_files)
    covered = sum(f["coveredLines"] for f in covered_files)
    gated = covered / executable * 100.0
    print(f"[{name}] GATED line coverage (over {len(covered_files)} covered "
          f"file(s), {covered}/{executable} lines): {gated:.2f}% "
          f"(required > {minimum:g}%)")

    if gated <= minimum:
        print(f"FAIL [{name}] coverage {gated:.2f}% <= {minimum:g}%; "
              f"least-covered files listed above")
        failed = True
    else:
        print(f"PASS [{name}]")

sys.exit(1 if failed else 0)
PY

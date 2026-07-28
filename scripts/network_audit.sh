#!/usr/bin/env bash
# Network audit (task 9.3; spec: monetization / privacy audit).
#
# The App Store label claim is "Data Not Collected". PrivacyAuditTests asserts the
# manifest and the absence of telemetry SDKs at RUNTIME, but it deliberately does not
# try to prove we link no networking framework — CFNetwork and Network.framework are
# loaded into every iOS process by UIKit whether or not we reference them, so a
# loaded-image scan cannot tell "we link it" from "the OS loaded it". That check has to
# happen at the LINK level, on the built products, which is what this script does.
#
# Two independent checks, because either alone is weak:
#   1. SOURCE — no networking API appears in our own Swift/ObjC sources.
#   2. LINK   — the built app and framework binaries declare no networking dependency.
#
# Exit non-zero on any finding, so CI fails rather than warns.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
FAILED=0
SKIPPED=0

echo "== 1. source audit =="
# ufbx is a VENDORED C FBX parser; its matches are URLs in comments and license text,
# not networking. Excluded by path with the reason stated rather than by a blanket
# --exclude that would also hide a real finding in our own code.
PATTERN='URLSession|NSURLConnection|NWConnection|NWListener|NWBrowser|CFSocket|NetService|Network\.framework|WebSocket|CFStream|getaddrinfo|BSD socket'
if MATCHES=$(grep -rInE "$PATTERN" App/Sources CyberKit/Sources \
        --include='*.swift' --include='*.m' --include='*.mm' --include='*.h' \
        2>/dev/null | grep -v '/ufbx/' || true); [ -n "$MATCHES" ]; then
    echo "FAIL: networking API referenced in app/CyberKit sources:"
    echo "$MATCHES"
    FAILED=1
else
    echo "ok: no networking API in App/Sources or CyberKit/Sources"
fi

echo
echo "== 2. link audit =="
# Only meaningful against a built product. Skipped LOUDLY rather than silently passing:
# a skipped check that reads as green is worse than no check.
PRODUCT_DIR="${NETWORK_AUDIT_PRODUCT_DIR:-}"
if [ -z "$PRODUCT_DIR" ]; then
    # Under Build/Products specifically: DerivedData also has an identically named
    # directory under Build/Intermediates.noindex, which holds no linked binaries and
    # made this check silently skip.
    PRODUCT_DIR=$(find "$HOME/Library/Developer/Xcode/DerivedData" \
        -maxdepth 5 -type d -name 'Debug-iphonesimulator' \
        -path '*CyberTopology*/Build/Products/*' 2>/dev/null | head -1 || true)
fi
if [ -z "$PRODUCT_DIR" ] || [ ! -d "$PRODUCT_DIR" ]; then
    echo "SKIP: no built product found. Build first, or set NETWORK_AUDIT_PRODUCT_DIR."
    echo "      (This check is not passing — it did not run.)"
    SKIPPED=1
else
    echo "product dir: $PRODUCT_DIR"
    BINARIES=$(find "$PRODUCT_DIR" -type f \( -name CyberTopology -o -name CyberKit \) \
        -perm +111 2>/dev/null | head -5 || true)
    if [ -z "$BINARIES" ]; then
        echo "SKIP: no CyberTopology/CyberKit binary in the product dir (did not run)."
        SKIPPED=1
    else
        for bin in $BINARIES; do
            # otool -L lists DIRECT dependencies only, which is exactly the distinction
            # the runtime scan could not make.
            if LINKS=$(otool -L "$bin" 2>/dev/null \
                    | grep -E 'CFNetwork|/Network\.framework' || true); [ -n "$LINKS" ]; then
                echo "FAIL: $(basename "$bin") directly links a networking framework:"
                echo "$LINKS"
                FAILED=1
            else
                echo "ok: $(basename "$bin") links no networking framework"
            fi
        done
    fi
fi

echo
echo "== 3. engine net module =="
# The engine HAS a net module (live-link, phase 8). It must be compiled OUT of the
# shipped iOS slices; it is ON only for host tests.
if grep -q -- '-DCYBER_BUILD_NET=OFF' Scripts/build_engine.sh; then
    echo "ok: build_engine.sh passes -DCYBER_BUILD_NET=OFF for the iOS slices"
else
    echo "FAIL: build_engine.sh no longer disables the engine net module for iOS"
    FAILED=1
fi
if grep -oE 'cyber_net[a-z0-9_]*' Engine/CyberRemesherAndUV/capi/include/cyber_capi.h \
        | head -1 | grep -q .; then
    echo "FAIL: a cyber_net_* entry point is exposed through the C API"
    FAILED=1
else
    echo "ok: no cyber_net_* entry point in the C API"
fi

echo
if [ "$FAILED" -ne 0 ]; then
    echo "network audit FAILED"
    exit 1
fi
if [ "$SKIPPED" -ne 0 ]; then
    # Never print a bare "passed" when a check did not run: a skipped audit that reads
    # as green is the failure mode this script exists to prevent. Non-zero under
    # NETWORK_AUDIT_STRICT so CI cannot go green on a partial audit.
    echo "network audit INCOMPLETE — the link check did not run"
    [ "${NETWORK_AUDIT_STRICT:-0}" = "1" ] && exit 1
    exit 0
fi
echo "network audit passed (all checks ran)"

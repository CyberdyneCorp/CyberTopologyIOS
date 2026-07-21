#!/usr/bin/env bash
#
# Builds the CyberRemesherAndUV C++ engine (git submodule at
# Engine/CyberRemesherAndUV) for iOS and packages it as a static
# xcframework consumed by the CyberKit Swift package (task 1.2).
#
# Outputs:
#   Engine/build/engine-ios/libCyberRemesher.a       (device, arm64)
#   Engine/build/engine-ios-sim/libCyberRemesher.a   (simulator, arm64)
#   Engine/build/CyberRemesherC.xcframework          (canonical artifact)
#   CyberKit/Binaries/CyberRemesherC.xcframework     (copy; SwiftPM binary
#                                                     targets must live
#                                                     inside the package)
#
# Idempotent: skips everything when the packaged xcframework is newer than
# the submodule checkout; `--force` rebuilds, `--sim-only` skips the device
# slice (what CI uses). Requires CMake >= 3.24, Ninja, Xcode 26.
#
# The two patches in Engine/patches/ are required for the engine to compile
# for iOS (upstream metal_backend.mm typo + std::system() unavailable on
# iOS). TODO(upstream): PR both one-liners to CyberRemesherAndUV and drop
# the patch step once merged.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE_SRC="$REPO_ROOT/Engine/CyberRemesherAndUV"
PATCH_DIR="$REPO_ROOT/Engine/patches"
BUILD_ROOT="$REPO_ROOT/Engine/build"
XCFRAMEWORK="$BUILD_ROOT/CyberRemesherC.xcframework"
PACKAGE_COPY="$REPO_ROOT/CyberKit/Binaries/CyberRemesherC.xcframework"
DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-18.0}"

FORCE=0
SIM_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        --sim-only) SIM_ONLY=1 ;;
        *) echo "usage: $0 [--force] [--sim-only]" >&2; exit 2 ;;
    esac
done

if [[ ! -f "$ENGINE_SRC/CMakeLists.txt" ]]; then
    echo "build_engine: engine submodule missing; run:" >&2
    echo "  git submodule update --init Engine/CyberRemesherAndUV" >&2
    exit 1
fi

# ---- idempotence check ------------------------------------------------
# Rebuild only when forced, when an artifact is missing, or when the
# submodule commit changed since the last build.
ENGINE_COMMIT="$(git -C "$ENGINE_SRC" rev-parse HEAD)"
STAMP="$BUILD_ROOT/.engine-commit"
if [[ $FORCE -eq 0 && -d "$XCFRAMEWORK" && -d "$PACKAGE_COPY" \
      && -f "$STAMP" && "$(cat "$STAMP")" == "$ENGINE_COMMIT" ]]; then
    echo "build_engine: up to date ($ENGINE_COMMIT); use --force to rebuild"
    exit 0
fi

# ---- iOS patches (idempotent: skip when already applied) ---------------
for patch in "$PATCH_DIR"/*.patch; do
    [[ -e "$patch" ]] || continue
    if git -C "$ENGINE_SRC" apply --reverse --check "$patch" 2>/dev/null; then
        echo "build_engine: $(basename "$patch") already applied"
    else
        echo "build_engine: applying $(basename "$patch")"
        git -C "$ENGINE_SRC" apply "$patch"
    fi
done

# ---- per-slice CMake builds --------------------------------------------
COMMON_FLAGS=(
    -G Ninja
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_SYSTEM_NAME=iOS
    -DCMAKE_OSX_ARCHITECTURES=arm64
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
    -DCYBER_ENABLE_METAL=ON
    -DCYBER_BUILD_RENDER=ON
    -DCYBER_BUILD_CLI=OFF
    -DCYBER_BUILD_TESTS=OFF
    -DCYBER_BUILD_NET=OFF
    -DCYBER_BUILD_CAPI_SHARED=OFF
)

build_slice() { # <build-dir-name> <sysroot>
    local dir="$BUILD_ROOT/$1" sysroot="$2"
    echo "build_engine: configuring $1 ($sysroot)"
    cmake -S "$ENGINE_SRC" -B "$dir" "${COMMON_FLAGS[@]}" \
        -DCMAKE_OSX_SYSROOT="$sysroot"
    cmake --build "$dir"
    # Merge the ~11 static component libs into one for the xcframework.
    rm -f "$dir/libCyberRemesher.a"
    local libs
    libs=$(find "$dir" -name '*.a' ! -name libCyberRemesher.a)
    # shellcheck disable=SC2086
    libtool -static -o "$dir/libCyberRemesher.a" $libs
}

build_slice engine-ios-sim iphonesimulator
SLICES=(-library "$BUILD_ROOT/engine-ios-sim/libCyberRemesher.a"
        -headers "$REPO_ROOT/Engine/headers")
if [[ $SIM_ONLY -eq 0 ]]; then
    build_slice engine-ios iphoneos
    SLICES+=(-library "$BUILD_ROOT/engine-ios/libCyberRemesher.a"
             -headers "$REPO_ROOT/Engine/headers")
fi

# ---- headers: engine C API + a module map so Swift can import it -------
rm -rf "$REPO_ROOT/Engine/headers"
mkdir -p "$REPO_ROOT/Engine/headers"
cp "$ENGINE_SRC/capi/include/cyber_capi.h" "$REPO_ROOT/Engine/headers/"
cat > "$REPO_ROOT/Engine/headers/module.modulemap" <<'EOF'
module CyberRemesherC {
    header "cyber_capi.h"
    export *
}
EOF

# ---- xcframework --------------------------------------------------------
rm -rf "$XCFRAMEWORK"
xcodebuild -create-xcframework "${SLICES[@]}" -output "$XCFRAMEWORK"

# SwiftPM requires binary targets to live inside the package directory.
rm -rf "$PACKAGE_COPY"
mkdir -p "$(dirname "$PACKAGE_COPY")"
cp -R "$XCFRAMEWORK" "$PACKAGE_COPY"

echo "$ENGINE_COMMIT" > "$STAMP"
echo "build_engine: done -> $XCFRAMEWORK"

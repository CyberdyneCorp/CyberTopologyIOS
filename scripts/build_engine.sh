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
# The submodule is pinned at the CyberRemesherAndUV v0.2.4 RELEASE, which now
# ships the manual-retopology C API NATIVELY. That layer grew out of the one
# this app first prototyped as a large local patch stack (commit 87a0bd8,
# carried upstream into the 0.1.0-0.2.4 release line), so only the app's own
# not-yet-upstreamed additions remain as patches, applied in numbered order
# before building:
#   0001  cybertopology stroke grammar: the device-tuned curated stroke
#         interpreter in retopo/stroke_interpreter.hpp - nearly-closed quad
#         rescue, create-triangle, X-before-closed delete detection, and the
#         four-gesture grammar cut (quad, triangle, delete, insert-loop). App
#         authoring policy; kept as a patch by design.
#   0002  cybertopology capi + engine additions: cyber_mesh_face_vertices (a
#         face's ring, for face-only Auto Relax + mirrored element edits),
#         cyber_retopo_subdivide_smooth / Mesh::smoothSubdivide (Catmull-Clark
#         smooth subdivision for the preview), plus the CreateTriangle action
#         wiring the stroke grammar needs. capi + core mesh op + commands.
#         TODO(upstream): PR face_vertices and smoothSubdivide.
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
# *effective source* changed since the last build. The effective source is
# the submodule commit AND the patch stack: patches change what gets built
# without moving the submodule commit, so a stamp of the commit alone would
# leave a stale xcframework (missing new C API symbols) after a pull that
# only added/edited Engine/patches/*.patch.
ENGINE_COMMIT="$(git -C "$ENGINE_SRC" rev-parse HEAD)"
# Hash file names + contents in lexical (apply) order; empty stack hashes
# the empty input. Renaming a patch reorders the stack, so names count.
PATCH_STACK_HASH="$(
    for patch in "$PATCH_DIR"/*.patch; do
        [[ -e "$patch" ]] || continue
        basename "$patch"
        cat "$patch"
    done | shasum -a 256 | awk '{print $1}'
)"
STAMP_VALUE="$ENGINE_COMMIT patches:$PATCH_STACK_HASH"
STAMP="$BUILD_ROOT/.engine-commit"
if [[ $FORCE -eq 0 && -d "$XCFRAMEWORK" && -d "$PACKAGE_COPY" \
      && -f "$STAMP" && "$(cat "$STAMP")" == "$STAMP_VALUE" ]]; then
    echo "build_engine: up to date ($STAMP_VALUE); use --force to rebuild"
    exit 0
fi

# ---- iOS patches (idempotent: skip when already applied) ---------------
# Later patches may add lines inside regions an earlier patch introduced;
# on such a tree the earlier patch is neither cleanly appliable nor cleanly
# reverse-checkable in isolation. That fully-patched state is recognized
# WITHOUT touching the working tree (see worktree_matches_full_stack); the
# script never resets the submodule on its own, so in-progress engine edits
# are never silently discarded.
apply_patch_stack() {
    local patch
    for patch in "$PATCH_DIR"/*.patch; do
        [[ -e "$patch" ]] || continue
        if git -C "$ENGINE_SRC" apply --reverse --check "$patch" 2>/dev/null; then
            echo "build_engine: $(basename "$patch") already applied"
        elif git -C "$ENGINE_SRC" apply --check "$patch" 2>/dev/null; then
            echo "build_engine: applying $(basename "$patch")"
            git -C "$ENGINE_SRC" apply "$patch"
        else
            return 1
        fi
    done
}

# True when the submodule's files exactly match HEAD with the ENTIRE patch
# stack applied — the overlapping-hunks state the per-patch checks in
# apply_patch_stack cannot recognize. Builds the expected tree in one
# throwaway index and snapshots the working tree (including files the
# patches CREATE, which `git diff <tree>` alone would miss as untracked)
# in a second; never mutates the working tree or the real index.
worktree_matches_full_stack() {
    local expected_index worktree_index expected_tree worktree_tree patch ok=1
    expected_index="$(mktemp)" || return 1
    worktree_index="$(mktemp)" || { rm -f "$expected_index"; return 1; }
    if GIT_INDEX_FILE="$expected_index" git -C "$ENGINE_SRC" read-tree HEAD 2>/dev/null; then
        for patch in "$PATCH_DIR"/*.patch; do
            [[ -e "$patch" ]] || continue
            if ! GIT_INDEX_FILE="$expected_index" git -C "$ENGINE_SRC" \
                    apply --cached "$patch" 2>/dev/null; then
                ok=0
                break
            fi
        done
        if [[ $ok -eq 1 ]]; then
            expected_tree="$(GIT_INDEX_FILE="$expected_index" \
                git -C "$ENGINE_SRC" write-tree 2>/dev/null)" || ok=0
        fi
        if [[ $ok -eq 1 ]]; then
            # Snapshot the working tree (tracked + untracked, .gitignore
            # respected) and compare tree hashes.
            if GIT_INDEX_FILE="$worktree_index" git -C "$ENGINE_SRC" \
                    read-tree HEAD 2>/dev/null \
                && GIT_INDEX_FILE="$worktree_index" git -C "$ENGINE_SRC" \
                    add -A . 2>/dev/null; then
                worktree_tree="$(GIT_INDEX_FILE="$worktree_index" \
                    git -C "$ENGINE_SRC" write-tree 2>/dev/null)" || ok=0
                [[ $ok -eq 1 && "$worktree_tree" == "$expected_tree" ]] || ok=0
            else
                ok=0
            fi
        fi
    else
        ok=0
    fi
    rm -f "$expected_index" "$worktree_index"
    [[ $ok -eq 1 ]]
}

if ! apply_patch_stack; then
    if worktree_matches_full_stack; then
        echo "build_engine: full patch stack already applied (overlapping hunks); continuing"
    else
        echo "build_engine: patch stack does not fit the current submodule tree," >&2
        echo "build_engine: and the tree does not match the recorded commit with all" >&2
        echo "build_engine: patches applied — it has local modifications this script" >&2
        echo "build_engine: refuses to discard. Either:" >&2
        echo "build_engine:   * commit/stash your engine work, or fold it into a new" >&2
        echo "build_engine:     numbered patch in Engine/patches/, then re-run; or" >&2
        echo "build_engine:   * reset the submodule yourself if the changes are disposable:" >&2
        echo "build_engine:       git -C Engine/CyberRemesherAndUV checkout -- ." >&2
        exit 1
    fi
fi

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
# --sim-only skips the device slice only when no prior device build exists
# (fresh CI runners). Once a device build dir is present, packaging an
# xcframework WITHOUT the device slice would silently break device builds
# from Xcode, and a stale device slice would be worse — so rebuild it
# incrementally (seconds after the first full build) and keep both slices.
if [[ $SIM_ONLY -eq 0 || -d "$BUILD_ROOT/engine-ios" ]]; then
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

echo "$STAMP_VALUE" > "$STAMP"
echo "build_engine: done -> $XCFRAMEWORK"

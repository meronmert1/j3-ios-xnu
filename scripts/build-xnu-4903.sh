#!/usr/bin/env bash
#
# build-xnu-4903.sh
#
# Try to build xnu-4903.270.47 (iOS 12 / macOS 10.14 era) for ARM64 + BCM2837 --
# Apple's own Cortex-A53 / 4K-page Raspberry Pi 3 target -- using a current Xcode.
#
# The goal of the first runs is NOT a working kernel. It is a complete, repeatable
# list of what a modern toolchain rejects, so the errors can be fixed one patch at
# a time. Fix patches go in patches/xnu-4903/*.patch and are applied automatically.
#
# Must run on macOS (Xcode required). Intended for a GitHub Actions macOS runner.
#
# Usage:
#   ./build-xnu-4903.sh                 # deps + kernel, stop at first failure
#   ./build-xnu-4903.sh --keep-going    # make -k: collect as many errors as possible
#   ./build-xnu-4903.sh --deps-only     # only build/install the build tools
#   ./build-xnu-4903.sh --kernel-only   # skip deps (already installed)
#   ./build-xnu-4903.sh --summary       # re-print the error summary of the last log
#   ./build-xnu-4903.sh --clean
#
# Environment knobs (all optional):
#   WORK_DIR            work tree               (default: ./.xnu-build)
#   XNU_SRC             use an existing xnu source tree instead of downloading
#   XNU_VERSION         default: 4903.270.47
#   KERNEL_CONFIG       RELEASE | DEVELOPMENT   (default: DEVELOPMENT)
#   ARCH_CONFIG         default: ARM64
#   MACHINE_CONFIG      default: BCM2837
#   NO_WERROR           1 = strip -Werror from makedefs    (default: 1)
#   LD_CLASSIC          1 | 0 | auto = add -Wl,-ld_classic (default: auto)
#   INSTALL_TOOLCHAIN   1 = copy mig/ctfconvert into the Xcode toolchain (default: 1)
#   JOBS                parallel make jobs      (default: hw.ncpu)
#   DTRACE_REF, BOOTSTRAP_CMDS_REF, AVAILABILITY_REF, LIBDISPATCH_REF
#
set -uo pipefail

# ---------------------------------------------------------------- configuration

WORK_DIR="${WORK_DIR:-$PWD/.xnu-build}"
XNU_VERSION="${XNU_VERSION:-4903.270.47}"
KERNEL_CONFIG="${KERNEL_CONFIG:-DEVELOPMENT}"
ARCH_CONFIG="${ARCH_CONFIG:-ARM64}"
MACHINE_CONFIG="${MACHINE_CONFIG:-BCM2837}"
NO_WERROR="${NO_WERROR:-1}"
LD_CLASSIC="${LD_CLASSIC:-auto}"
INSTALL_TOOLCHAIN="${INSTALL_TOOLCHAIN:-1}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

# xnu-4903 is from the macOS 10.14 release train. The host tools (mig, ctfconvert,
# availability.pl) are host-side and newer versions are fine; libfirehose_kernel is
# linked into the kernel, so it should come from the matching 10.14 libdispatch.
DTRACE_REF="${DTRACE_REF:-}"             # empty = newest tag
BOOTSTRAP_CMDS_REF="${BOOTSTRAP_CMDS_REF:-}"
AVAILABILITY_REF="${AVAILABILITY_REF:-}"
LIBDISPATCH_REF="${LIBDISPATCH_REF:-libdispatch-1008}"   # prefix match, 10.14 train

SRC_DIR="$WORK_DIR/src"
DEPS_DIR="$WORK_DIR/deps"
FAKEROOT="$WORK_DIR/fakeroot"
TOOLCHAIN_DST="$WORK_DIR/toolchain"
LOG_DIR="$WORK_DIR/logs"
BUILD_LOG="$LOG_DIR/kernel-build.log"
PATCH_DIR="${PATCH_DIR:-$PWD/patches/xnu-4903}"

OSS="https://github.com/apple-oss-distributions"

# ---------------------------------------------------------------------- helpers

say()  { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

# Newest tag of an apple-oss-distributions repo matching a prefix.
newest_tag() { # repo prefix
    git ls-remote --tags --refs "$OSS/$1" 2>/dev/null \
        | awk -F/ '{print $NF}' | grep "^$2" | sort -V | tail -1
}

# Clone an apple-oss-distributions repo at a tag (or newest tag with that prefix).
fetch_oss() { # repo prefix_or_tag -> echoes path
    local repo="$1" ref="${2:-}" dst="$DEPS_DIR/$1"
    [ -d "$dst/.git" ] && { echo "$dst"; return 0; }
    if [ -z "$ref" ] || ! git ls-remote --exit-code --tags "$OSS/$repo" "$ref" >/dev/null 2>&1; then
        ref="$(newest_tag "$repo" "${ref:-$repo-}")"
        [ -n "$ref" ] || die "no usable tag found for $repo"
    fi
    info "$repo @ $ref" >&2
    git clone --quiet --depth 1 --branch "$ref" "$OSS/$repo" "$dst" \
        || die "clone failed: $repo @ $ref"
    echo "$dst"
}

xcode_major() { xcodebuild -version 2>/dev/null | awk 'NR==1{split($2,v,"."); print v[1]}'; }

# ------------------------------------------------------------------ xnu sources

fetch_xnu() {
    if [ -n "${XNU_SRC:-}" ]; then
        [ -d "$XNU_SRC" ] || die "XNU_SRC=$XNU_SRC does not exist"
        say "Using existing xnu tree: $XNU_SRC"
        return
    fi
    XNU_SRC="$SRC_DIR/xnu-$XNU_VERSION"
    [ -d "$XNU_SRC" ] && { say "xnu source already present"; return; }

    say "Fetching xnu-$XNU_VERSION"
    mkdir -p "$SRC_DIR"
    # Apple retired the tarball site; the GitHub mirrors still carry the tags.
    local tag="xnu-$XNU_VERSION"
    for repo in "https://github.com/apple/darwin-xnu" \
                "https://github.com/apple-oss-distributions/xnu"; do
        info "trying $repo @ $tag"
        if git clone --quiet --depth 1 --branch "$tag" "$repo" "$XNU_SRC"; then
            return
        fi
        rm -rf "$XNU_SRC"
    done
    die "could not fetch $tag from any mirror"
}

apply_patches() {
    [ -d "$PATCH_DIR" ] || return 0
    local p applied="$XNU_SRC/.patches-applied"
    for p in "$PATCH_DIR"/*.patch; do
        [ -e "$p" ] || continue
        grep -qxF "$(basename "$p")" "$applied" 2>/dev/null && continue
        info "patch: $(basename "$p")"
        (cd "$XNU_SRC" && patch -p1 --forward --silent < "$p") \
            || die "patch failed: $p"
        basename "$p" >> "$applied"
    done
}

# Modern clang finds far more warnings than the 2018 one; -Werror turns every one
# of them into a hard stop and hides the real errors.
patch_no_werror() {
    [ "$NO_WERROR" = "1" ] || return 0
    local f="$XNU_SRC/makedefs/MakeInc.def"
    grep -qE '^[[:space:]]*WERROR[[:space:]]*:?=' "$f" || { warn "no WERROR line in MakeInc.def"; return 0; }
    grep -q 'xnu-build: werror stripped' "$f" && return 0
    sed -i '' -E 's/^([[:space:]]*WERROR[[:space:]]*:?=).*/\1 # xnu-build: werror stripped/' "$f"
    info "-Werror disabled in makedefs/MakeInc.def"
}

# Xcode 15 and later default to the new linker, which does not accept the kernel
# link flags this era of xnu uses. -ld_classic selects the old one.
patch_ld_classic() {
    local want="$LD_CLASSIC"
    if [ "$want" = "auto" ]; then
        [ "$(xcode_major)" -ge 15 ] 2>/dev/null && want=1 || want=0
    fi
    [ "$want" = "1" ] || return 0
    local f="$XNU_SRC/makedefs/MakeInc.def"
    grep -q 'xnu-build: ld_classic' "$f" && return 0
    printf '\n# xnu-build: ld_classic\nLDFLAGS_KERNEL_GEN += -Wl,-ld_classic\n' >> "$f"
    info "added -Wl,-ld_classic"
}

# ------------------------------------------------------------------ build tools

build_deps() {
    mkdir -p "$DEPS_DIR" "$FAKEROOT" "$TOOLCHAIN_DST"

    say "AvailabilityVersions"
    local d; d="$(fetch_oss AvailabilityVersions "$AVAILABILITY_REF")" || exit 1
    (cd "$d" && make install DSTROOT="$TOOLCHAIN_DST" >>"$LOG_DIR/deps.log" 2>&1) \
        || die "AvailabilityVersions build failed (see $LOG_DIR/deps.log)"

    say "bootstrap_cmds (mig)"
    d="$(fetch_oss bootstrap_cmds "$BOOTSTRAP_CMDS_REF")" || exit 1
    # The project file gets renamed across releases -- bootstrap_cmds-138
    # ships mig.xcodeproj, not bootstrap_cmds.xcodeproj -- so find it.
    proj="$(ls -d "$d"/*.xcodeproj 2>/dev/null | head -1)"
    [ -n "$proj" ] || die "no xcodeproj in $d"
    info "project $(basename "$proj")" >&2
    (cd "$d" && xcodebuild install -sdk macosx -project "$(basename "$proj")" \
        -alltargets DSTROOT="$TOOLCHAIN_DST" >>"$LOG_DIR/deps.log" 2>&1) \
        || die "bootstrap_cmds build failed (see $LOG_DIR/deps.log)"

    say "dtrace (ctfconvert / ctfmerge / ctfdump)"
    d="$(fetch_oss dtrace "$DTRACE_REF")" || exit 1
    (cd "$d" && xcodebuild install -sdk macosx -target ctfconvert -target ctfdump \
        -target ctfmerge ARCHS="arm64 x86_64" VALID_ARCHS="arm64 x86_64" \
        DSTROOT="$TOOLCHAIN_DST" >>"$LOG_DIR/deps.log" 2>&1) \
        || die "dtrace build failed (see $LOG_DIR/deps.log)"

    # xnu's makefiles locate these with `xcrun -find`, so they have to live inside
    # the active toolchain, not just in PATH.
    if [ "$INSTALL_TOOLCHAIN" = "1" ]; then
        say "Installing tools into the active Xcode toolchain"
        local tc; tc="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain"
        sudo ditto "$TOOLCHAIN_DST/usr" "$tc/usr" || die "ditto failed"
        for t in mig migcom ctfconvert ctfmerge; do
            xcrun -find "$t" >/dev/null 2>&1 || warn "xcrun cannot find $t yet"
        done
    fi

    say "xnu headers -> fakeroot"
    (cd "$XNU_SRC" && make installhdrs SDKROOT=macosx ARCH_CONFIGS="$ARCH_CONFIG" \
        SRCROOT="$XNU_SRC" OBJROOT="$WORK_DIR/hdr-obj" DSTROOT="$FAKEROOT" \
        >>"$LOG_DIR/deps.log" 2>&1) \
        || die "xnu installhdrs failed (see $LOG_DIR/deps.log)"

    say "libfirehose_kernel (libdispatch)"
    d="$(fetch_oss libdispatch "$LIBDISPATCH_REF")" || exit 1
    (cd "$d" && xcodebuild install -sdk macosx -target libfirehose_kernel \
        PRODUCT_NAME=firehose_kernel DSTROOT="$FAKEROOT" \
        >>"$LOG_DIR/deps.log" 2>&1) \
        || die "libfirehose_kernel build failed (see $LOG_DIR/deps.log)"
}

# ----------------------------------------------------------------------- kernel

build_kernel() { # $1 = extra make flags
    say "Building kernel: ${KERNEL_CONFIG}_${ARCH_CONFIG}_${MACHINE_CONFIG}"
    info "log: $BUILD_LOG"
    ( cd "$XNU_SRC" && make -j"$JOBS" ${1:-} \
        SDKROOT=macosx \
        ARCH_CONFIGS="$ARCH_CONFIG" \
        KERNEL_CONFIGS="$KERNEL_CONFIG" \
        MACHINE_CONFIGS="$MACHINE_CONFIG" \
        SRCROOT="$XNU_SRC" \
        OBJROOT="$WORK_DIR/obj" \
        SYMROOT="$WORK_DIR/sym" \
        DSTROOT="$WORK_DIR/dst" \
        FAKEROOT_DIR="$FAKEROOT" \
        BUILD_WERROR=0 BUILD_LTO=0 \
    ) > >(tee "$BUILD_LOG") 2>&1
    local rc=${PIPESTATUS[0]}

    local out
    out="$(find "$WORK_DIR/obj" -maxdepth 3 -name 'kernel.*' -type f 2>/dev/null | head -5)"
    if [ -n "$out" ]; then
        say "Kernel binaries produced"
        printf '%s\n' "$out"
        file $out
    fi
    return "$rc"
}

# Group the log into "which error, how many times" -- the only view that matters
# when the first run throws hundreds of lines.
summary() {
    [ -f "$BUILD_LOG" ] || die "no build log at $BUILD_LOG"
    local n; n="$(grep -c 'error:' "$BUILD_LOG" 2>/dev/null || echo 0)"
    echo "### xnu-$XNU_VERSION / $KERNEL_CONFIG $ARCH_CONFIG $MACHINE_CONFIG"
    echo
    echo "Toolchain: $(xcodebuild -version 2>/dev/null | tr '\n' ' ')"
    echo
    echo "Total \`error:\` lines: **$n**"
    echo
    echo '#### Most frequent errors'
    echo '```'
    grep -hoE 'error: .*' "$BUILD_LOG" | sed 's/^error: //' \
        | sed -E "s/'[^']*'/'X'/g" | sort | uniq -c | sort -rn | head -40
    echo '```'
    echo
    echo '#### Files with the most errors'
    echo '```'
    grep -hoE '^[^ ]+\.(c|cpp|h|s|S):[0-9]+:[0-9]+: error' "$BUILD_LOG" \
        | cut -d: -f1 | sort | uniq -c | sort -rn | head -20
    echo '```'
    echo
    echo '#### Link / undefined symbols'
    echo '```'
    grep -hE 'Undefined symbols|ld: |_[A-Za-z0-9_]+", referenced from' "$BUILD_LOG" \
        | sort | uniq -c | sort -rn | head -20
    echo '```'
}

# ------------------------------------------------------------------------- main

MODE="all"
MAKE_FLAGS=""
for a in "$@"; do
    case "$a" in
        --keep-going|-k) MAKE_FLAGS="-k" ;;
        --deps-only)     MODE="deps" ;;
        --kernel-only)   MODE="kernel" ;;
        --summary)       MODE="summary" ;;
        --clean)         MODE="clean" ;;
        -h|--help)       sed -n '2,32p' "$0"; exit 0 ;;
        *)               die "unknown option: $a" ;;
    esac
done

mkdir -p "$LOG_DIR"

case "$MODE" in
    summary) summary; exit 0 ;;
    clean)   rm -rf "$WORK_DIR"; say "cleaned $WORK_DIR"; exit 0 ;;
esac

[ "$(uname -s)" = "Darwin" ] || die "macOS only -- run this on a Mac or a macOS CI runner"
command -v xcodebuild >/dev/null || die "Xcode command line tools not found"

say "Toolchain"
xcodebuild -version
clang --version | head -1
info "SDK: $(xcrun --sdk macosx --show-sdk-path 2>/dev/null)"

fetch_xnu
apply_patches
patch_no_werror
patch_ld_classic

[ "$MODE" != "kernel" ] && build_deps
[ "$MODE" = "deps" ] && { say "deps done"; exit 0; }

build_kernel "$MAKE_FLAGS"
rc=$?

echo
summary | sed 's/^#\+ //'
exit "$rc"

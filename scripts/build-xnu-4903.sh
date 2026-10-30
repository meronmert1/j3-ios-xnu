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

PWD_AT_START="$PWD"
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
LIBDISPATCH_REF="${LIBDISPATCH_REF:-libdispatch-1008.270.1}" # companion to xnu-4903.270.47
LIBPLATFORM_REF="${LIBPLATFORM_REF:-libplatform-177}"
LIBPTHREAD_REF="${LIBPTHREAD_REF:-libpthread-330.250.2}"   # 10.14.6 train, matches xnu-4903
HFS_REF="${HFS_REF:-hfs-407.30.1}"                  # the 10.14 tag that still ships core/

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

# ---------------------------------------------------------------------- hfs

# xnu-4903 has no HFS. Apple moved it out of xnu after 10.12 and into its own
# project, and bsd/vfs/vfs_conf.c here does not mention it -- which is fine,
# because the kext registers itself with vfs_fsadd() rather than through that
# table, and its vfs_fsentry carries VFS_TBLCANMOUNTROOT.
#
# Only some tags of the hfs project ship the kernel sources: hfs-407.50.6 and
# hfs-407.200.4 have the userland tools and no core/ directory. hfs-407.30.1
# is the 10.14-line tag that has it.
#
# The names are left alone. None of the 40 sources collides with an existing
# xnu object, so unlike the pthread kext nothing needs renaming.
#
# Apple's layout is kept rather than flattened: core/hfs.h includes
# "../hfs_encodings/hfs_encodings.h" and hfs_encodings/hfs_encodinghint.c
# includes "../core/hfs.h", so the two directories have to stay siblings.
#
# Only hfs_encodinghint.c is taken from hfs_encodings. hfs_catalog.c calls
# hfs_pickencoding() from a branch guarded by !TARGET_OS_EMBEDDED rather than
# by CONFIG_HFS_STD, so the symbol has to exist -- but with CONFIG_HFS_STD=0
# the encoding tables compile away and a stub is all that is left.
# hfs_encodings.c is a different kext (HFSEncodings) and everything it defines
# is reached only through the standard-HFS path, so it is left out.
#
# core/kext-config.h is not copied: it is a prefix header (GCC_PREFIX_HEADER
# in core/kext.xcconfig), no source includes it, and it keys the configuration
# off TARGET_OS_EMBEDDED -- which would turn on CONFIG_PROTECT and pull in
# AppleKeyStore key wrapping that does not exist here. The configuration is
# passed as -D flags by the patch instead.
#
# The matching patch is patches/xnu-4903/hfs-filesystem-builtin.patch.
stage_hfs() {
    local dst="$XNU_SRC/bsd/hfs"
    [ -f "$dst/core/hfs_vfsops.c" ] && { info "hfs already staged"; return 0; }

    say "hfs (filesystem, built into the kernel)"
    mkdir -p "$DEPS_DIR"
    local d; d="$(fetch_oss hfs "$HFS_REF")" || exit 1

    [ -d "$d/core" ] || die "hfs: $HFS_REF has no core/ -- wrong tag"
    [ -d "$d/hfs_encodings" ] || die "hfs: $HFS_REF has no hfs_encodings/"

    rm -rf "$dst"
    mkdir -p "$dst/core" "$dst/hfs_encodings"

    cp "$d"/core/*.c "$d"/core/*.cpp "$d"/core/*.h "$dst/core/" \
        || die "hfs: could not stage core/"
    rm -f "$dst/core/kext-config.h"

    cp "$d"/hfs_encodings/hfs_encodinghint.c \
       "$d"/hfs_encodings/hfs_encodings.h \
       "$d"/hfs_encodings/hfs_encodings_internal.h "$dst/hfs_encodings/" \
        || die "hfs: could not stage hfs_encodings/"

    local n
    n="$(ls "$dst"/core/*.c "$dst"/core/*.cpp "$dst"/hfs_encodings/*.c \
         | wc -l | tr -d ' ')"
    info "staged $n sources into bsd/hfs (core + hfs_encodings)"
}

# -------------------------------------------------------------- pthread kext

# xnu carries no pthread implementation: bsd/pthread/pthread_shims.c is a table
# of function pointers, and the only thing that ever fills it is
# com.apple.kec.pthread, the kext half of Apple's libpthread. Without it
# bsd_init() panics at pthread_init(), and no process could create a thread
# even if it got that far. There are no kexts in this port, so the kext is
# compiled into the kernel and its sources are staged into the xnu tree here.
#
# libpthread's own directory layout is preserved, because the sources include
# each other by project-relative path ("kern/synch_internal.h", "pthread/qos.h",
# "private/qos_private.h"). The angle-bracket includes -- bsdthread_private.h,
# priority_private.h, workqueue_syscalls.h -- are xnu's own and are not staged.
#
# Two sources are renamed on the way in. kern_synch.c would collide with xnu's
# own bsd/kern/kern_synch.c, because the conf system names objects after the
# basename alone. The names chosen are the ones Apple used while this code
# still lived in xnu, and bsd/conf/Makefile.template in this tree still carries
# warning suppressions written for them.
#
# The matching patch is patches/xnu-4903/pthread-kext-builtin.patch.
stage_libpthread() {
    local dst="$XNU_SRC/bsd/pthread/kext"
    [ -f "$dst/kern/pthread_synch.c" ] && { info "pthread kext already staged"; return 0; }

    say "libpthread (pthread kext, built into the kernel)"
    mkdir -p "$DEPS_DIR"
    local d; d="$(fetch_oss libpthread "$LIBPTHREAD_REF")" || exit 1

    mkdir -p "$dst/kern" "$dst/pthread" "$dst/private" "$dst/sys/_pthread"

    local f
    for f in kern_internal.h synch_internal.h workqueue_internal.h kern_trace.h; do
        cp "$d/kern/$f" "$dst/kern/$f" || die "libpthread: no kern/$f"
    done
    cp "$d/pthread/qos.h"         "$dst/pthread/qos.h"         || die "libpthread: no pthread/qos.h"
    cp "$d/private/qos_private.h" "$dst/private/qos_private.h" || die "libpthread: no private/qos_private.h"

    # qos.h and qos_private.h name types that live in libpthread too, not in
    # xnu. Only qos_class_t and the QOS_CLASS_* constants are reachable from a
    # kernel build; the rest is behind #ifndef KERNEL.
    cp "$d/sys/qos.h"         "$dst/sys/qos.h"         || die "libpthread: no sys/qos.h"
    cp "$d/sys/qos_private.h" "$dst/sys/qos_private.h" || die "libpthread: no sys/qos_private.h"
    for f in _pthread_types.h _pthread_attr_t.h _pthread_t.h; do
        cp "$d/sys/_pthread/$f" "$dst/sys/_pthread/$f" || die "libpthread: no sys/_pthread/$f"
    done

    cp "$d/kern/kern_init.c"    "$dst/kern/pthread_kext.c"    || die "libpthread: no kern/kern_init.c"
    cp "$d/kern/kern_support.c" "$dst/kern/pthread_support.c" || die "libpthread: no kern/kern_support.c"
    cp "$d/kern/kern_synch.c"   "$dst/kern/pthread_synch.c"   || die "libpthread: no kern/kern_synch.c"

    info "staged into bsd/pthread/kext"
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

    # bsd/sys/make_symbol_aliasing.sh looks for availability.pl inside the SDK
    # rather than the toolchain, and the public SDK does not ship it.
    local sdk; sdk="$(xcrun --sdk macosx --show-sdk-path)"
    [ -n "$sdk" ] || die "cannot locate the macOS SDK"
    sudo ditto "$TOOLCHAIN_DST/usr/local/libexec" "$sdk/usr/local/libexec" \
        || die "could not stage availability.pl into the SDK"
    [ -x "$sdk/usr/local/libexec/availability.pl" ] \
        || die "availability.pl not executable in the SDK"
    info "availability.pl -> $sdk/usr/local/libexec"

    say "bootstrap_cmds (mig)"
    d="$(fetch_oss bootstrap_cmds "$BOOTSTRAP_CMDS_REF")" || exit 1
    # The project file gets renamed across releases -- bootstrap_cmds-138
    # ships mig.xcodeproj, not bootstrap_cmds.xcodeproj -- so find it.
    proj="$(ls -d "$d"/*.xcodeproj 2>/dev/null | head -1)"
    [ -n "$proj" ] || die "no xcodeproj in $d"
    # Its install script chowns to root:wheel, which a normal user cannot do.
    sed -i '' -e 's/-o root -g wheel //g' "$d"/xcodescripts/*.sh 2>/dev/null
    info "project $(basename "$proj")" >&2
    (cd "$d" && xcodebuild install -sdk macosx -project "$(basename "$proj")" \
        -alltargets DSTROOT="$TOOLCHAIN_DST" >>"$LOG_DIR/deps.log" 2>&1) \
        || die "bootstrap_cmds build failed (see $LOG_DIR/deps.log)"

    say "dtrace (ctfconvert / ctfmerge / ctfdump)"
    d="$(fetch_oss dtrace "$DTRACE_REF")" || exit 1
    # Command-line tool targets want a signing identity; CI has none, and
    # these only ever run locally during the build.
    (cd "$d" && xcodebuild install -sdk macosx -target ctfconvert -target ctfdump \
        -target ctfmerge ARCHS="arm64 x86_64" VALID_ARCHS="arm64 x86_64" \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
        DSTROOT="$TOOLCHAIN_DST" >>"$LOG_DIR/deps.log" 2>&1) \
        || die "dtrace build failed (see $LOG_DIR/deps.log)"

    # xnu's makefiles locate these with `xcrun -find`, so they have to live inside
    # the active toolchain, not just in PATH.
    if [ "$INSTALL_TOOLCHAIN" = "1" ]; then
        say "Installing tools into the active Xcode toolchain"
        local tc; tc="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain"
        sudo ditto "$TOOLCHAIN_DST/usr" "$tc/usr" 2>/dev/null
        # bootstrap_cmds installs into $DSTROOT$DT_TOOLCHAIN_DIR, so the
        # staging root mirrors the real toolchain's absolute path.
        [ -d "$TOOLCHAIN_DST$tc/usr" ] && sudo ditto "$TOOLCHAIN_DST$tc/usr" "$tc/usr"
        for t in mig migcom ctfconvert ctfmerge; do
            xcrun -find "$t" >/dev/null 2>&1 || warn "xcrun cannot find $t yet"
        done
    fi

    say "xnu headers -> fakeroot"
    # ARM builds ask Apple's internal embedded_device_map for the Mach-O arch
    # name. That tool is not in the public SDK, so the variable comes back
    # empty and every -arch flag loses its value. Supply it directly.
    (cd "$XNU_SRC" && make installhdrs SDKROOT=macosx ARCH_CONFIGS="$ARCH_CONFIG" \
        ARCH_STRING_FOR_CURRENT_MACHINE_CONFIG=arm64 \
        SRCROOT="$XNU_SRC" OBJROOT="$WORK_DIR/hdr-obj" DSTROOT="$FAKEROOT" \
        >>"$LOG_DIR/deps.log" 2>&1) \
        || die "xnu installhdrs failed (see $LOG_DIR/deps.log)"

    say "libfirehose_kernel"
    # The real one, built from libdispatch, not the stub it used to be.
    #
    # logd needs it. It maps the kernel's os_log buffer with LOGBUFFERMAP and
    # traps -- "BUG IN LIBDISPATCH: Unexpected kernel buffer size" -- unless
    # the size it gets back is between FIREHOSE_BUFFER_KERNEL_MIN_CHUNK_COUNT
    # and MAX times FIREHOSE_CHUNK_SIZE, which is 64 KiB to 256 KiB. The stub
    # returned NULL from __firehose_buffer_create(), which left
    # kernel_firehose_addr zero and the size zero, and logd died on every
    # boot, taking the system log with it.
    #
    # The stub existed because the firehose private headers were taken from
    # the SDK, where they belong to a much newer libdispatch. They do not have
    # to come from there. libdispatch-1008.270.1 is the companion release to
    # xnu-4903.270.47 -- the same Darwin 18.7.0, the same .270. -- it is
    # already fetched here for its os/*.h, and it carries the source Apple
    # builds as libfirehose_kernel. Built against xnu's own installed headers
    # in $FAKEROOT rather than the SDK's, there is no version to mismatch.
    #
    # The flags are Apple's, from xcodeconfig/libfirehose_kernel.xcconfig, with
    # $SDKROOT replaced by $FAKEROOT. OS_FIREHOSE_SPI is passed because the
    # body of firehose_buffer.c is wrapped in it and no xcconfig defines it for
    # compilation; Apple writes its intended value in the unifdef flags.
    mkdir -p "$FAKEROOT/usr/local/lib/kernel"
    local ldd; ldd="$(fetch_oss libdispatch "$LIBDISPATCH_REF")" || exit 1
    mkdir -p "$FAKEROOT/usr/local/include/kernel/os"
    cp "$ldd"/os/*.h "$FAKEROOT/usr/local/include/kernel/os/" 2>/dev/null
    # libdispatch wraps the whole header in #if OS_FIREHOSE_SPI; xnu includes
    # it without ever defining that, so the file arrives empty.
    sed -i '' -e 's/^#if OS_FIREHOSE_SPI$/#if 1 \/* OS_FIREHOSE_SPI, which xnu never defines *\//' \
        "$FAKEROOT/usr/local/include/kernel/os/firehose_buffer_private.h"
    (cd "$WORK_DIR" && xcrun clang -arch arm64 -mkernel -nostdinc -Wno-packed \
        -Wall -DKERNEL=1 -DOS_FIREHOSE_SPI=1 -DDISPATCH_USE_DTRACE=0 \
        -I"$ldd" -I"$ldd/os" -I"$ldd/src/firehose" \
        -I"$FAKEROOT/System/Library/Frameworks/Kernel.framework/PrivateHeaders" \
        -I"$FAKEROOT/System/Library/Frameworks/Kernel.framework/Headers" \
        -I"$FAKEROOT/usr/local/include/firehose" \
        -I"$FAKEROOT/usr/local/include/kernel" \
        -I"$FAKEROOT/usr/local/include" \
        -I"$(xcrun --sdk macosx --show-sdk-path)/usr/include" \
        -c "$ldd/src/firehose/firehose_buffer.c" \
        -o firehose_buffer.o >>"$LOG_DIR/deps.log" 2>&1 \
     && xcrun ar rcs "$FAKEROOT/usr/local/lib/kernel/libfirehose_kernel.a" \
        firehose_buffer.o >>"$LOG_DIR/deps.log" 2>&1) \
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
        ARCH_STRING_FOR_CURRENT_MACHINE_CONFIG=arm64 \
        SRCROOT="$XNU_SRC" \
        OBJROOT="$WORK_DIR/obj" \
        SYMROOT="$WORK_DIR/sym" \
        DSTROOT="$WORK_DIR/dst" \
        FAKEROOT_DIR="$FAKEROOT" \
        BUILD_WERROR=0 BUILD_LTO=0 \
        LDFLAGS_KERNEL_SDK="-L$FAKEROOT/usr/local/lib/kernel" \
        INCFLAGS_SDK="-I$FAKEROOT/usr/local/include/kernel -I$FAKEROOT/usr/local/include" \
    ) > >(tee "$BUILD_LOG") 2>&1
    local rc=${PIPESTATUS[0]}

    # Keep the assym inputs and outputs: when the extraction misparses, the
    # errors it causes name constants, never the file that should define them.
    find "$WORK_DIR/obj" -name 'genassym.o' -exec sh -c \
        'head -c 20000 "$1" > "$2/genassym-head.txt"' _ {} "$LOG_DIR" \; 2>/dev/null
    find "$WORK_DIR/obj" -name 'assym.s' -exec cp {} "$LOG_DIR/" \; 2>/dev/null
    grep -h 'DEFINITION__define__' "$LOG_DIR/genassym-head.txt" 2>/dev/null \
        | head -20 > "$LOG_DIR/genassym-lines.txt"

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
stage_libpthread
stage_hfs
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

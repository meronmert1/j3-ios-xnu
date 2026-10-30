#!/usr/bin/env python3
"""Replace the libfirehose_kernel stub in build-xnu-4903.sh with the real one.

Why
---
logd dies on every boot:

    Exception Type: EXC_BREAKPOINT (SIGTRAP)
    0  logd  0x100f4ffcc  (logd + 16332)

and the instruction before the trap stores a message into the crash-info
struct:

    "BUG IN LIBDISPATCH: Unexpected kernel buffer size"

logd asks the kernel for the os_log firehose buffer with
LOGBUFFERMAP (_IOR('t', 79, firehose_buffer_map_info_t), 0x4010744F) and
then checks the size it gets back:

    sub x9, x8, #0x10, lsl #12      ; size - 65536
    cmp x9, #0x30, lsl #12          ; vs 196608
    b.hi <trap>                     ; so 65536 <= size <= 262144

Those two bounds are the kernel's own:
FIREHOSE_BUFFER_KERNEL_MIN_CHUNK_COUNT (16) and MAX (64) times
FIREHOSE_CHUNK_SIZE (4096). logd is enforcing xnu's documented contract,
and we hand it zero, because oslog_init() ends with

    kernel_firehose_addr = (vm_offset_t)__firehose_buffer_create(&size);

and the stub returns NULL, throwing away the buffer the line above had just
allocated. The other branch is no better: a failing ioctl traps too, with
"Unable to map kernel buffer". logd does not run without a real buffer.

The stub was written because the firehose private headers "only exist in
the current SDK, written for a much newer libdispatch". That was the right
diagnosis and the wrong conclusion: the headers do not have to come from
the SDK. libdispatch-1008.270.1 is the companion release to xnu-4903.270.47
-- same Darwin 18.7.0, matching .270. -- it is already being fetched by this
script for its os/*.h, and it carries src/firehose/firehose_buffer.c, which
Apple builds as libfirehose_kernel with the xcconfig in the same tree.

So: build it, against xnu's own installed headers in $FAKEROOT rather than
the SDK's. The flags are Apple's, from xcodeconfig/libfirehose_kernel.xcconfig:

    GCC_PREPROCESSOR_DEFINITIONS = KERNEL=1 DISPATCH_USE_DTRACE=0
    OTHER_CFLAGS = -mkernel -nostdinc -Wno-packed
    HEADER_SEARCH_PATHS = $(PROJECT_DIR) Kernel.framework/{PrivateHeaders,Headers}
                          $(SDKROOT)/usr/local/include/{os,firehose}

with $SDKROOT replaced by $FAKEROOT, which is the whole point.
OS_FIREHOSE_SPI is passed too: the body of firehose_buffer.c is wrapped in
#if OS_FIREHOSE_SPI and no xcconfig defines it for compilation -- Apple
passes it in COPY_HEADERS_UNIFDEF_FLAGS, which is where its intended value
is written down.

Usage:
    enable-firehose.py path/to/scripts/build-xnu-4903.sh
    enable-firehose.py path/to/scripts/build-xnu-4903.sh --dry-run
"""

import argparse
import io
import re
import sys

NEW = r'''    say "libfirehose_kernel"
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
        -c "$ldd/src/firehose/firehose_buffer.c" \
        -o firehose_buffer.o >>"$LOG_DIR/deps.log" 2>&1 \
     && xcrun ar rcs "$FAKEROOT/usr/local/lib/kernel/libfirehose_kernel.a" \
        firehose_buffer.o >>"$LOG_DIR/deps.log" 2>&1) \
        || die "libfirehose_kernel build failed (see $LOG_DIR/deps.log)"
'''

# From the first line of the stub block to the last, whatever is between.
PATTERN = re.compile(
    r'[ \t]*say "libfirehose_kernel \(stub\)".*?'
    r'\|\| die "firehose stub build failed \(see \$LOG_DIR/deps\.log\)"\n',
    re.S)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("script", help="scripts/build-xnu-4903.sh")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    s = io.open(args.script, encoding="utf-8").read()

    if 'say "libfirehose_kernel"' in s and "firehose_buffer.c" in s:
        print("already done: this script builds the real libfirehose_kernel")
        return 0

    found = PATTERN.findall(s)
    if len(found) != 1:
        sys.stderr.write(
            "enable-firehose: expected exactly one stub block, found %d.\n"
            "The script has changed; not touching it.\n" % len(found))
        return 2

    old = found[0]
    out = s.replace(old, NEW)

    print("replacing %d lines with %d"
          % (old.count("\n"), NEW.count("\n")))
    if args.dry_run:
        print("--- old ---")
        print(old, end="")
        print("--- new ---")
        print(NEW, end="")
        print("dry run: nothing written")
        return 0

    io.open(args.script, "w", encoding="utf-8").write(out)
    print("written. scripts/firehose-stub.c is now unused.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

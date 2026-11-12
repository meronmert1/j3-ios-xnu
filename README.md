XNU For Galaxy J3 2017

## Status

### Works

- **Boot chain.** xnu-4903 boots on the Galaxy J3 2017 (j3y17lte, Exynos 7570)
  from a stock-format Android boot.img, through a custom shim that builds an
  Apple Device Tree and boot_args and jumps to the kernel.
- **Storage.** `dwmmc` driver reads the iOS system volume off the internal eMMC
  and reads/writes the Data partition. HFS+ root mounts; `fsck_hfs` runs.
- **Console.** The kernel draws to the panel through S-Boot's framebuffer
  (720x1280x32), so the whole boot is readable without a UART.
- **Timebase.** 26 MHz, taken from Samsung's own device tree. The kernel's idea
  of elapsed time now matches a wristwatch.
- **launchd and the daemon set.** The full LaunchDaemon set loads; around
  **90 processes** come up, including backboardd, securityd, lsd, profiled,
  containermanagerd, apsd, bluetoothd, mDNSResponder, CommCenter and
  SpringBoard itself.
- **IOMobileFramebuffer / IOSurface shims.** backboardd opens the framebuffer,
  sets a mode, registers for vsync and frame-info notifications, and the frame
  clock runs. The swap path is implemented end to end: a submitted surface is
  copied to the panel and the kernel console is handed over.
- **Kernel-side diagnostics.** Periodic process roll call, live user-space
  backtraces of named processes, and a port report that shows queue depth,
  whether a kqueue is watching, the sending pid and the message id.

### Partially works

- **Data volume.** Mounts and is writable, but `fsck_hfs` repairs it on every
  boot, so nothing written there survives reliably.
- **Daemons.** They start, but several respawn in a loop: cloudpaird,
  mobileactivationd, pkd, imagent, CallHistorySyncH, coreduetd, assistantd.
  The loop consumes the single enabled core and fills the corpse quota, which
  suppresses crash reports for everything else.
- **Display.** The path is complete and proven in code, but no frame has been
  submitted yet, because the window server never gets that far. Rendering is a
  full-screen CPU `memcpy` per frame; there is no GPU.
- **mobileactivationd.** The four `/chosen` properties it wants are now in the
  ADT (certificate-production-status, effective-production-status-ap,
  certificate-security-mode, effective-security-mode-sep) and it still exits
  with SIGTRAP.

### Does not work

- **Synchronous XPC / mach IPC replies.** This is the single blocker. Messages
  reach their target's port and are never taken off it; callers wait forever.
  libdispatch's synchronous wait has no failure path at all -- its default
  branch is `cbnz w0, brk #1` -- so a missing reply is an unbreakable hang, and
  a timeout cannot be introduced from either side. Measured: a ten second
  timeout fired in syslogd, misd, installd, backboardd, routined, timed, awdd
  and lsd within the first half minute.
  Two distinct faults are visible in the port report: ports holding mail with a
  kqueue watching them and nobody woken, and ports holding mail with no watcher
  at all.
- **SpringBoard UI.** SpringBoard launches and survives, but has not drawn a
  frame. Its blocked thread has been traced to a synchronous LaunchServices
  call, and later to CoreFoundation subscribing to system notifications
  through distnoted inside a `dispatch_once`.
- **Setup / hello screen.** Not reached.
- **Everything below the UI**: touch, GPU, audio, cellular, Wi-Fi, SEP,
  activation, sleep, multicore (boots with `cpus=1`).

### Notes for anyone reading the logs

- Disabling a daemon by destroying its Mach-O magic is **not** neutral on this
  port. The daemon cannot check in, launchd keeps its service port, and every
  synchronous question sent there waits for the rest of the boot. A daemon that
  crashes and respawns is recoverable; one that cannot start is a permanent
  hang for anything that asks it something.
- `CNTFRQ_EL0` reads 0 on this board: Samsung's EL3 firmware does not program it
  for the non-secure world. The timebase has to come from the device tree.


## Thanks to

Claude (for port and coding)
ios-sweet (for patches)
and other iOS ports created for Android

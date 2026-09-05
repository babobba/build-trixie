# Plan: automated checks that every program on the image can run

**Status: implemented.** All four steps are in the tree; `docs/testing.md`
describes how to run them. What they found on the first runs, all fixed:

- e2fsprogs, util-linux-extra (hwclock, in trixie), rfkill and bc were not
  on the image at all: the save-file creator, peasyclock and peasywifi
  called programs that did not exist. Added to every config's BASE_INSTALL.
- The initrd carried a 32-bit `askpass` asking for a loader it did not
  have (unused; mkinitrd now drops it), and `xfs` and `f2fs` were in
  `initrd-src/modlist` but never copied in, so mkinitrd silently dropped
  them from the built list (now copied).
- `defaultfilemanager` pointed at a file manager that is not installed
  (pfind's default); the build now points it at the one that is.
- `iputils-ping` was missing, so scripts that ping had nothing to call.

The sections below are the plan as written before the work; the
implementation follows it, with these departures: the guest program test
does not start the `/usr/local/bin` scripts (they act on their arguments
rather than parse them, and are covered statically instead), the GUI
programs list comes from the config's `.desktop` files plus the yad and
gtkdialog tools, and windows are detected by comparing xdotool's window
list before and after rather than by process id, since Firefox and pcmanfm
hand off to another process first.

## Goal

Two questions, answered automatically on every build:

1. Does every executable on the image have what it needs to start: shared
   libraries, interpreters, symlink targets, alternatives, terminfo, its
   .desktop entry pointing at something real?
2. Does every program the image ships actually run, on the booted system:
   command-line programs, terminal (ncurses) programs, and X programs?

The first is static and cheap and belongs with the image tests. The second
needs a booted guest and belongs with the boot tests. Together they cover
the classes of breakage met so far: a script left behind by a removed
interpreter (mailcap after perl), a menu entry with no program (synaptic),
locale and documentation stripping that a program trips over at start,
modules the kernel cannot load on first use.

## What exists to build on

- Debian's `adequate` package (in trixie) checks an installed system from
  dpkg's metadata: missing shared libraries, undefined symbols, broken
  symlinks, missing alternatives, missing binfmt interpreters, Python
  modules not byte-compiled. It covers everything that came from a package,
  which is about 90% of the image.
- The image test layer (`tests/image/`) already mounts the built squashfs;
  the host can stack a tmpfs overlay on it, so a test can chroot in and run
  the image's own dynamic loader safely.
- The boot harness runs a report script in the guest at the cliexec stage
  (no X) and another at the guiexec stage (desktop up), and asserts on what
  they print. xdotool, wmctrl, `script` and `timeout` are in the image.
- The config names the packages the image is for; `dpkg -L` on them gives
  the list of programs to exercise, so no list has to be maintained by hand.

## Steps

### Step 1: static checks on the squashfs (`tests/image/test_executables.sh`)

Mount `01-filesystem.squashfs` read-only, put a tmpfs upper over it with
overlayfs, chroot into the result. Then:

- Install nothing: `adequate` is added to the build's package list so it is
  on the image (it is small) and run inside the chroot with `--all`. Fail on
  `library-not-found`, `undefined-symbol`, `broken-symlink`,
  `missing-alternative`, `missing-binfmt`. Record the rest.
- Every ELF under /usr/bin, /usr/sbin, /usr/libexec, /usr/local/bin and the
  plugin directories (gtk, gdk-pixbuf, xorg modules): `ldd` inside the
  chroot, fail on "not found". This is what covers files the overlay or a
  dog package placed by hand, which adequate does not know about.
- Every script in /usr/local/bin and the overlay: the `#!` interpreter
  exists; `sh -n` or `bash -n` passes; every word in a command position that
  looks like a program name resolves with `command -v`, with a short list of
  known-optional names.
- Every `.desktop` file: `desktop-file-validate` passes and the first word of
  `Exec=` resolves. Entries carried by a module (Firefox) are checked when
  the module is mounted alongside.
- Every alternative in /etc/alternatives points at a file that exists.

Acceptance: runs in under a minute as root, skips without a build, and
fails on a deliberately broken image (remove one library from the tmpfs
upper and watch it fail) before it is committed as passing.

Effort: half a day.

### Step 2: command-line and terminal programs in the guest (`tests/linuxrc/boot-test-programs.sh`)

At the cliexec stage, from the list of executables in the packages the
config names plus /usr/local/bin:

- Command-line: `timeout 10 prog --version </dev/null`, then
  `timeout 10 prog --help </dev/null` if the first is refused. Pass means:
  the process was not killed by a signal, and stderr carries no
  "error while loading shared libraries", "No such file or directory",
  "cannot open shared object", or "Segmentation fault". Exit status is
  recorded, not asserted; usage-and-exit-1 is normal.
- A denylist of programs that act without arguments and must never be
  probed: shutdown, poweroff, halt, reboot, telinit, kexec, mkfs.*, mke2fs,
  mkswap, wipefs, dd, shred, fdisk, sfdisk, parted, xinit, startx. The list
  is in the test, with each name's reason.
- Terminal programs (nano, alsamixer, dialog, aptitude, top, less, and the
  dog tools that use dialog): run inside `script -qc "timeout 5 prog" /dev/null`
  with `TERM=linux`. Pass means exit status 124 (it ran until killed) and
  no "Error opening terminal" or "terminals database is inaccessible" in the
  capture.

The report prints one line per program; the test asserts on the lines. A
program that is missing from the medium altogether is a failure, not a
skip, since the list came from the config.

Acceptance: about 100 programs, under three minutes under QEMU; added to
`boot-test-all.sh`.

Effort: half a day.

### Step 3: X programs in the guest (`boot-test-gui.sh`)

At the guiexec stage, with the desktop up, for each GUI program from the
same package list (those with a .desktop file, plus the yad and gtkdialog
dog tools):

- `timeout 90 prog &`, then poll `xdotool search --pid $!` until a window
  appears, up to the program's budget (Firefox needs about 90 s under
  emulation; most GTK programs 10 to 20 s). Then `xdotool key --window
  <id> Escape` or `kill`, and check the process ended.
- Pass means a window appeared and stderr carries none of the loader
  errors from step 2 nor "cannot open display" or "Gtk-ERROR".
- Programs that need a root password prompt or a device (gparted, the
  remaster tools) get a note in the list and are started with their
  dialogs expected.

This test is slow and can be flaky under emulation, so it runs on its own
and not in `boot-test-all.sh` by default; it is the one to run before a
release, not after every change.

Acceptance: every program in the default configs opens a window; the test
takes a screendump of any failure for the log.

Effort: a day, most of it on timing under emulation.

### Step 4: the initrd

The initrd is not a Debian userland and none of the above reaches it.
Extend `test_initrd_applets.sh` to run `ldd` over the initrd's own ELF files
(blockdev and its libraries, the dynamic loader itself) inside the
unpacked initrd tree, and to check that every module named in `modlist`
and every alias pattern file the loader relies on is present. This is
where the forensic blockdev with a dangling loader would have been caught.

Effort: an hour.

## Order and dependencies

1 first: it is one package and one command for most of the value, and it
runs without booting. 4 next, since it is small and the initrd has already
bitten twice. Then 2, then 3. Steps 2 and 3 share the program-list logic,
which should live in `boot-lib.sh` so the list is derived once.

## Decisions to make

- Whether `adequate` stays on the shipped image (it is about 100 KB and
  useful to a user after installing packages) or is installed only into
  the chroot for the check and removed before the squashfs is made.
- The size of the denylist versus an allowlist: derive from packages and
  deny by name (the plan above), or hand-list what to run. Deriving keeps
  the test honest when the config changes; the denylist must then be
  reviewed when a new package brings a program that acts without arguments.
- Whether step 3 runs in the release checklist only, or nightly on the
  build box where its half-hour does not matter.

## What this does not cover

Programs that start but do the wrong thing. That is what the cheatcode
tests and the image tests are for; this plan is about "can it run at all",
which is the failure mode that has been silent so far.

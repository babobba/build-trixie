# Testing the image

Three layers, each answering a different question, each usable on its own.

| Layer | Question | Needs | Time |
|---|---|---|---|
| `tests/linuxrc/run.sh` | Do the initrd scripts do what the cheatcodes promise? | nothing: no root, no build | seconds |
| `tests/image/run.sh` | Is the built root filesystem sound? | root, a build in `trixie/isodata` | a minute |
| `tests/linuxrc/boot-test-all.sh` | Does the image boot, by every path we ship? | root, a build, qemu, ovmf | ~3 min per boot, 9 boots |

Run all three before pushing a change to `initrd-src`, `build-trixie`, the
`dog-boot-*` overlay or a config. The unit tests are the fast loop; the boot
tests are the proof.

## Unit tests: `tests/linuxrc/test_*.sh`

Each file exercises one cheatcode or one piece of the initrd against a fake
root built under `/tmp/linuxrc-tests`: `lib.sh` builds a tree that looks like
a DebianDog rootfs, `run_cheats "<kernel cmdline>"` runs linuxrc's cheatcode
block against it, and the test asserts on what was written. Nothing is
booted, nothing needs root.

```
./tests/linuxrc/run.sh            # every file
sh tests/linuxrc/test_login.sh    # one
```

Two files guard things the others cannot see:

- `test_initrd_applets.sh` checks that linuxrc and finit call only applets the
  initrd's busybox has. The initrd is not a Debian userland: `head`, `dirname`,
  `awk` and `expr` do not exist there, and a call to one fails silently at
  boot. This is the test that caught forensic protecting nothing.
- `test_modlist.sh` pins the module-loading design: which modules are loaded by
  name, which come from the hardware's modaliases, and the soft dependencies
  busybox's modprobe cannot follow (crc32c for ext4, the nls tables for FAT).

## Image tests: `tests/image/`

These mount `trixie/isodata/live/01-filesystem.squashfs` read-only and look at
it as files. They skip, rather than fail, without a build.

```
sudo ./tests/image/run.sh                  # the last build
sudo ./tests/image/run.sh /path/to/rootfs  # an unpacked tree
```

- `test_origins.sh` reads the distribution and the init from the image itself
  and checks that the packages are what that combination should have: Debian
  archives only, https everywhere, no repository whose key never arrived, and
  the right init packages present and the wrong ones absent.
- `test_dpkg_verify.sh` runs `dpkg --verify` and accepts only the deletions the
  build makes on purpose (docs, man, locales, the udev vendor tables) and a
  listed set of changed files, each with its reason. A file that changed
  without a reason fails.
- `test_fhs.sh` checks the layout against the FHS, with one documented
  exception.

A skipped file is counted as a skip, not a pass; the runner exits 2 if
nothing ran.

## Boot tests: `tests/linuxrc/boot-test-*.sh`

Every boot test rebuilds the initrd from `initrd-src` before booting, so the
working tree's scripts are what boots, not whatever the last full build
packed. The medium is a test ISO made from `trixie/isodata` with the test's
boot line as the default entry; the guest reports through a script the
initrd runs at the cliexec stage, writing to the serial port, and the test
asserts on those lines.

```
sudo ./tests/linuxrc/boot-test-all.sh             # everything on this branch
sudo NAME=x CODES=forensic ./tests/linuxrc/boot-test-readonly.sh
sudo FIRMWARE=uefi-secure ./tests/linuxrc/boot-test-uefi.sh
```

What each one proves:

| Test | Boot line | Proves |
|---|---|---|
| `boot-test.sh` | most cheatcodes at once | the cheatcodes take effect end to end |
| `boot-test-readonly.sh` | `readonly`, or `forensic` with `CODES=forensic` | a found disk is mounted read-only (readonly) or blocked at the device (forensic); uses a scratch disk |
| `boot-test-nomagic.sh` | magic folders, or `nomagic` | a folder on a found disk is bound over the union, or not |
| `boot-test-pxe.sh` | `pxe` | the PXE server setup script is generated and runs |
| `boot-test-image.sh` | `login=`, `disable-services=`, `nobluetooth` | the image is the one the config asks for (init, distribution) and the systemd handoff survived |
| `boot-test-modules.sh` | no `base_only` | the split module (Firefox) loads and runs, and the base does not carry it |
| `boot-test-uefi.sh` | through OVMF | EFI runtime services, 64-bit firmware, efivars, medium found |
| `boot-test-uefi.sh` with `FIRMWARE=uefi-secure` | OVMF enforcing, Microsoft keys enrolled | only Microsoft-signed shim and a grub it trusts got this far; `SecureBoot=1` read from the guest |
| `boot-test-systemd.sh` | our initrd, MiniOS's rootfs | the initrd works against a systemd rootfs that knows nothing about us |

Knobs, all environment variables read by `boot-lib.sh`:

- `ISODATA` (default `trixie/isodata`), `NAME` (work dir `/tmp/linuxrc-NAME`)
- `CODES` extra cheatcodes; `REPORT` extra shell for the in-guest report
- `SCRATCH=1` attaches a partitioned scratch disk
- `BASE_ONLY=0` loads the medium's extra modules (default 1: every test but the
  modules test boots the base alone, so a module can never hide a broken base)
- `FIRMWARE=bios|uefi|uefi-secure`, with `OVMF_CODE` and `OVMF_VARS` to point
  at other firmware files
- `CLI_TIMEOUT` (180 s) and `GUI_TIMEOUT` (240 s)

Two harness details worth knowing because they cost a wrong result once each:
the isolinux `APPEND` must be one line (a backslash continuation is silently
dropped), and the guest's `echo` eats backslashes, so the report is written
with `printf`.

## Building without a keyboard

`build-trixie` stops for input in several places and exits 0 on some of its
own failures. `tools/build-unattended <config> [gzip|xz|zstd]` drives it
with expect, supplies the passwords and the compressor, and exits non-zero
when the base system failed to install. It is what every rebuild in the
test chains uses.

## Running from a scratch copy of another branch

`git worktree add /tmp/wt-x <branch>` gives a second checkout with its own
`trixie/` build directory; point the tests at it with
`ISODATA=/tmp/wt-x/trixie/isodata`. This is how the sysvinit and systemd
images are tested side by side on one machine.

## Requirements

Host packages: `qemu-system-x86`, `ovmf`, `xorriso`, `isolinux`, `cpio`,
`squashfs-tools`, `mtools`, `dosfstools`, `expect`. Root for anything that
mounts a squashfs or attaches a disk. No KVM is needed; without it every
boot runs under TCG, roughly six times slower than the same hardware.

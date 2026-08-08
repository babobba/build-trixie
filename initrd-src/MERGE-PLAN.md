# linuxrc: merging Porteus / PorteuX cheatcodes

## Base

`initrd-src/linuxrc` (and `finit`) stay the base. They descend from an aufs-era
Porteus `linuxrc` by brokenman, which fredx181 forward-ported to overlayfs and
adapted for Debian: `.squashfs` modules instead of `.xzm`, `/live` instead of
`/porteus`, Debian kernel module layout, and DebianDog userland integration.

Neither upstream is a usable base here. Porteus and PorteuX are Slackware
distributions whose init scripts assume `/porteus` or `/porteux`, `.xzm`
modules and Slackware's `rc.S` model, and neither publishes its initrd as
source — the script ships only as a binary inside `initrd.xz`. PorteuX's
repository contains the module build system but no initrd source, and carries
no LICENSE file. Fred's is the only one of the three available as text and
already speaking Debian.

Porteus v5.0 is the naming and semantics authority: its spelling is what users
already have in their boot lines. PorteuX supplies the ideas Porteus lacks.

## Why the script is now tracked

`initrdport-bullseye.tar.gz` is a binary blob, so every past change to
`linuxrc` was an unreviewable tarball diff. `initrd-src/linuxrc` and
`initrd-src/finit` are now tracked as text, and `build-trixie` overlays them
onto the extracted skeleton before running `mkinitrd`. The binary skeleton
(busybox, uClibc, cryptsetup askpass) stays in the tarball — only the scripts
are extracted, so the repository does not gain binaries.

## Cheatcode inventory

Common to all three (21): `base_only` `changes=` `changes-ro` `copy2ram`
`delay=` `extramod=` `from=` `fsck` `load=` `mopt` `noauto` `nocd` `nohd`
`noload=` `nonetwork` `norootcopy` `noswap` `rammod=` `ramsize=` `rootcopy=`
`vga_detect`

Fred-only, kept: `pfull=` `ip=` `nfspath=` `nvidia_detect` `nonvidia` `log`

## What this change implements

Ported from Porteus v5.0 unless marked otherwise. Each is implemented the
Debian way rather than by copying Slackware logic — writing the config file
Debian already reads is a much smaller patch than reimplementing Porteus's
runtime.

| Cheatcode | Source | Implementation |
| --- | --- | --- |
| `nohotplug` | Porteus | Skip the `modlist` modprobe loop |
| `kmap=` | both | `XKBLAYOUT` in `/etc/default/keyboard` |
| `timezone=` | both | `/etc/timezone` + relink `/etc/localtime` |
| `utc` | both | Write `/etc/adjtime` with `UTC` |
| `volume=` | both | `amixer set Master N%` via `/etc/rc.local` |
| `login=` | both | Autologin user in `/etc/inittab` |
| `cliexec=` | both | Commands into `/etc/rc.local`, before X starts |
| `guiexec=` | both | Commands into the Openbox `autostart` files |
| `zram=` | both | zram swap set up from `/etc/rc.local` |
| `sgnfile=` | Porteus | Alias for fred's existing `cfgfile=` |
| `nologin` | PorteuX | Disable autologin, plain getty on tty1 |
| `nobluetooth` | PorteuX | Disable `/etc/init.d/bluetooth` |
| `noupdateclock` | PorteuX | Disable `/etc/init.d/hwclock.sh` |
| `rootmount` | PorteuX | Bind-mount rootcopy files instead of copying |
| `fscknolog` | PorteuX | Run `fsck` quietly, log kept in the boot log |

`cliexec=` and `guiexec=` follow Porteus syntax: `;` separates commands, `~`
stands in for a space.

## Bugs fixed alongside

- `nonetwork` and `bluetooth` targeted Slackware paths (`/etc/rc.d/rc.inet1`,
  `rc.networkmanager`, `rc.bluetooth`). None exist in a DebianDog image — the
  image ships only `/etc/rc.d/rc.network` — so both codes silently did
  nothing. They now act on `/etc/init.d/`.
- `nomagic` appeared in `isodata/isolinux/live.cfg` but is not implemented
  anywhere in the initrd. Porteus's "magic folders" have no DebianDog
  equivalent, so the dead cheatcode is removed from the boot menu rather than
  implemented.

## Deliberately not ported

- `pxe` and `storage=` — fred already boots over NFS via `ip=` and `nfspath=`.
  Making the hardcoded `/srv/pxe` paths configurable is worthwhile but is a
  change to the NFS boot path, which deserves its own commit and a PXE server
  to test against.
- `nomagic` — no DebianDog equivalent, see above.

## Testing

`build-trixie configs-trixie/default.conf` must still produce a bootable ISO,
and the ISO must boot to the desktop with no cheatcodes given, proving the
defaults path is untouched. Each new code is then checked by booting with it
set and inspecting the file it is supposed to have written.

## Running the tests

`tests/linuxrc/` holds the unit tests. They lift the relevant region out of
`linuxrc` (or a function out of `finit`), stub the initrd's `param`/`value`
cheatcode readers and a `/union` that mirrors a DebianDog rootfs, and assert on
what the code writes. No root, no built ISO:

    ./tests/linuxrc/run.sh

`test_defaults.sh` is the regression guard: it boots with no cheatcodes and
asserts that `rc.local`, `inittab`, `/etc/default/keyboard` and the Openbox
autostart files come out byte-identical. Known gaps are marked `xfail`, which
does not fail the suite but does fail if the behaviour starts working, so a
marker cannot outlive the gap it documents.

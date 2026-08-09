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
| `volume=` | both | `amixer set Master N%`, before X starts |
| `login=` | both | Autologin user in `/etc/inittab`, or the display manager |
| `cliexec=` | both | Commands run before X starts |
| `guiexec=` | both | XDG autostart entry + Openbox autostart, run once |
| `zram=` | both | zram swap, set up before X starts |
| `sgnfile=` | Porteus | Alias for `cfgfile=`; `cfgfile=` wins if both given |
| `nologin` | PorteuX | Disable autologin in `/etc/inittab` and the display manager |
| `nobluetooth` | PorteuX | Disable `/etc/init.d/bluetooth` |
| `noupdateclock` | PorteuX | Disable `/etc/init.d/hwclock.sh` |
| `rootmount` | PorteuX | Bind-mount rootcopy files; recreate dirs/symlinks |
| `storage=` | Porteus | Where a netbooted client's changes are kept |
| `fscknolog` | PorteuX | Run `fsck` quietly, log kept in the boot log |

`cliexec=` and `guiexec=` follow Porteus syntax: `;` separates commands, `~`
stands in for a space.

`guiexec=` runs its commands once per boot. The lock that prevents the XDG
entry and the Openbox entry from both firing is keyed to the boot id, so
restarting X within a session will not start them a second time.

One deliberate difference from Porteus: the default marker file used to locate
the boot medium is the initrd itself, `initrd1.xz`, not a `.sgn` file. A
Porteus boot line that relies on the default therefore has to name its marker
explicitly with `sgnfile=`. A marker that cannot be found is fatal rather than
silently ignored, so a typo fails loudly instead of booting the wrong medium.

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

- `pxe` — on Porteus this turns the booted machine into a PXE *server*, by
  starting tftpd, dhcpcd and an NFS server. None of those daemons is in a
  DebianDog image, so there is nothing for the cheatcode to start. It would
  need `tftpd-hpa`, a DHCP server and `nfs-kernel-server` added to the config
  first, at which point it is a feature in its own right rather than a
  cheatcode port.
- `nomagic` — no DebianDog equivalent, see above.

## Testing

`build-trixie configs-trixie/default.conf` must still produce a bootable ISO,
and the ISO must boot to the desktop with no cheatcodes given, proving the
defaults path is untouched. Each new code is then checked by booting with it
set and inspecting the file it is supposed to have written.

### Boot testing without waiting for a desktop

Every cheatcode has finished its work before X starts, so a boot test does not
need the desktop. Have the guest report over the serial port and stop as soon
as it does:

    label SPEED-TEST
    menu default
    kernel /live/vmlinuz1
    append initrd=/live/initrd1.xz from=/ base_only cliexec=/usr/local/bin/report

with `report` installed through `live/rootcopy` and starting
`exec > /dev/ttyS0 2>&1`, then:

    qemu-system-x86_64 -accel tcg,thread=multi -m 3072 -smp 4 \
      -cdrom test.iso -boot d -display none -serial file:serial.log

That reaches the report in about 85 seconds, against roughly 20 minutes to
reach a painted desktop. Serial also timestamps *when* something happened,
which a screenshot cannot.

Measured on this hardware, one sample each, same ISO and same milestone:
IDE CD-ROM with single-threaded TCG 90s, IDE with `thread=multi` 85s, virtio
disk with `thread=multi` 80s. The differences between the three are close to
run-to-run noise, because under TCG the boot is CPU-bound in instruction
translation rather than I/O-bound. Choosing the earlier milestone is what
makes the difference, not the disk interface.

The virtio row matters for a different reason: before the VM drivers were
added it did not boot at all. Note that QEMU rejects UNIX socket paths longer
than 107 bytes, which is easy to hit when putting monitor sockets under a long
scratchpad path.

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

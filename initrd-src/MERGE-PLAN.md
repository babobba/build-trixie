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
| `guiexec=` | both | XDG autostart + Openbox autostart, once per X session |
| `zram=` | both | zram swap, set up before X starts |
| `sgnfile=` | Porteus | Alias for `cfgfile=`; `cfgfile=` wins if both given |
| `nologin` | PorteuX | Disable autologin in `/etc/inittab` and the display manager |
| `nobluetooth` | PorteuX | Disable `/etc/init.d/bluetooth` |
| `noupdateclock` | PorteuX | Disable `/etc/init.d/hwclock.sh` |
| `rootmount` | PorteuX | Bind-mount rootcopy files; recreate dirs/symlinks |
| `storage=` | Porteus | Where a netbooted client's changes are kept |
| `fscknolog` | PorteuX | Run `fsck` quietly, log kept in the boot log |
| `readonly` | new | Mount discovered filesystems read-only (`noload` on ext) |
| `forensic` | new | `blockdev --setro` on every disk and partition |
| `nomagic` | Porteus | Skip binding the magic folders |

`cliexec=` and `guiexec=` follow Porteus syntax: `;` separates commands, `~`
stands in for a space.

`guiexec=` starts its commands once per X session. The lock that stops the XDG
entry and the Openbox entry from both firing is keyed to the running X server,
so logging out and back in starts them again, which is what "run when the
graphical interface loads" should mean. If the X server cannot be identified
the lock falls back to the boot id, degrading to once per boot rather than
running twice.

`cliexec=` stays keyed to the boot, since it stands in for a runlevel change:
it should not re-run when someone logs out of tty1 and back in.

One deliberate difference from Porteus: the default marker file used to locate
the boot medium is the initrd itself, `initrd1.xz`, not a `.sgn` file. A
Porteus boot line that relies on the default therefore has to name its marker
explicitly with `sgnfile=`. A marker that cannot be found is fatal rather than
silently ignored, so a typo fails loudly instead of booting the wrong medium.

## Not writing to the machine's disks

Finding the boot medium means mounting every partition, and the default mount
options are read-write, so an ordinary boot updates the superblock of every
ext partition it finds and lets ntfs-3g write its log. `noauto` does not
prevent that: it unmounts afterwards, so it limits what the session can reach
but not what the boot already wrote.

`readonly` mounts them read-only instead, through the same `MOPT` that
`fstab()` and `mount_device()` already use. ext3 and ext4 additionally get
`noload`, because a read-only mount still replays a dirty journal, and that
replay is a write to the filesystem the cheatcode exists to leave alone.

`forensic` adds the block layer's read-only flag on every disk and partition
via `blockdev --setro`, before anything is mounted. It implies `readonly` out
of necessity, not caution: a read-write mount of a device the block layer has
marked read-only fails, so without read-only mount options the boot medium
would never be found.

Neither is a write blocker, and the name `forensic` describes the intent
rather than a guarantee. Root can clear the flag with `blockdev --setrw`, it
does not cover SCSI passthrough, and `blkid` still reads every device to
identify it. Evidence handling wants hardware write blocking. What these do is
remove the writes an ordinary boot makes.

Both are opt-in. Persistence bind-mounts and loop-mounts under `/mnt/<dev>` in
fifteen places, all needing a writable filesystem, so a read-only default
would break `changes=` for everyone; given either code, `changes=` falls back
to memory through the existing `is_writable` path. `fsck` is skipped for the
same reason.

`mopt=ro,noatime` achieves much of `readonly` on an unmodified initrd, if you
need it before this merges.

## What the initrd can actually run

`linuxrc` and `finit` do not run on Debian. They run inside `initrd1.xz`, on a
busybox 1.31.1 built with a reduced applet set plus whatever `mkinitrd` copies
in. There is no `awk`, no `dirname`, no `head`, no `expr`, no `seq`. `printf`
and `let` are fine, but only because they are ash builtins.

This matters more than it sounds, because the failure is silent. Most of
`linuxrc` calls out from inside command substitution with stderr discarded, so
a missing command does not stop the boot or print anything — the variable just
comes back empty and the script carries on with a wrong value. Two live
examples were found by looking rather than by testing:

- `blockdev --setro` was applied to whole disks but never to partitions,
  because the partition name came from `` `basename `dirname $PD`` ``. On a
  partitioned disk — that is, on essentially every real machine — `forensic`
  protected nothing that mattered.
- the netboot interface probe fell back to `ls /sys/class/net | head -1`, so
  on any machine whose first interface is not `eth0` the client's MAC could
  not be read.

Both had passing unit tests, because the unit tests run the extracted regions
under the host's `/bin/sh`, where all of these commands exist.
`tests/linuxrc/test_initrd_applets.sh` closes that gap by checking the source
text against the initrd's real applet inventory. Code that `linuxrc` *writes*
for the booted system is excluded — the `zram=` snippet's `awk` is correct,
because it runs from `/etc/rc.local` in a full Debian userland.

The rule when editing these two files: if it is not an applet in that
inventory and not an ash builtin, use parameter expansion or `sed`, both of
which are always there.

## Bugs fixed alongside

- `nonetwork` and `bluetooth` targeted Slackware paths (`/etc/rc.d/rc.inet1`,
  `rc.networkmanager`, `rc.bluetooth`). None exist in a DebianDog image — the
  image ships only `/etc/rc.d/rc.network` — so both codes silently did
  nothing. They now act on `/etc/init.d/`.
- `nomagic` appeared in `isodata/isolinux/live.cfg` while nothing in the
  initrd implemented it. It is now real: magic folders are implemented, and
  `nomagic` skips them.

## Deliberately not ported

- `pxe` — on Porteus this turns the booted machine into a PXE *server*, by
  starting tftpd, dhcpcd and an NFS server. None of those daemons is in a
  DebianDog image, so there is nothing for the cheatcode to start. It would
  need `tftpd-hpa`, a DHCP server and `nfs-kernel-server` added to the config
  first, at which point it is a feature in its own right rather than a
  cheatcode port.

## Magic folders

Porteus's magic folders bind individual directories from real storage over
paths in the live system, so those paths persist without a whole-system
`changes=` file — useful for a Downloads folder or a mail profile when you do
not want everything else saved.

The pairs live in `/etc/magic_folders`, one per line, source first:

    # anything after a # is ignored
    /mnt/sdb1/Downloads  /home/puppy/Downloads
    /mnt/sdb1/mail.dat   /home/puppy/.thunderbird

A source directory is bind-mounted. A source *file* is treated as a filesystem
image and loop-mounted, which is how FAT and NTFS media are supported: they
cannot hold a bind-mountable Linux directory tree, so Porteus uses a container
file there and this does the same.

The file normally arrives through `rootcopy`, so the binding happens straight
after rootcopy is applied and before the switch to the new root.

Targets are checked before anything is mounted. A target must be absolute, may
not contain `..`, and may not be `/`, `/proc`, `/sys`, `/dev`, `/mnt`,
`/memory` or `/union` — binding over any of those breaks the boot outright,
and a live system that cannot boot is exactly the situation `nomagic` exists
to rescue. Bad pairs are named on the console rather than skipped silently.

With `readonly` or `forensic` given, magic folders still bind but inherit the
read-only mount, so writes to them fail.

`tests/linuxrc/boot-test-nomagic.sh` boots this twice from one ISO. The first
boot delivers an `/etc/magic_folders` through `rootcopy` that exercises every
branch at once — a good pair, a source on a device that does not exist, a
relative target, a target containing `..`, a pair with no target at all, and a
pair aiming at `/proc` — and then checks from inside the booted system that the
good pair is a live mountpoint holding the file from the disk, that `/proc` is
still a procfs, and that nothing was created for the rejected pairs. The second
boot adds `nomagic` and requires the first boot's effect to be absent.

The scratch disk it binds from is partitioned, so the source path is
`/mnt/sda1/...`. The config lists `/mnt/sdb1/...` as well; whichever does not
exist reports itself on the console, which is the "source not found" case
tested for free.

## Testing

`build-trixie configs-trixie/default.conf` must still produce a bootable ISO,
and the ISO must boot to the desktop with no cheatcodes given, proving the
defaults path is untouched. Each new code is then checked by booting with it
set and inspecting the file it is supposed to have written.

### Boot testing

`tests/linuxrc/boot-test.sh` builds a throwaway ISO from a built `isodata`
tree, boots it under QEMU, and checks both that the guest reaches each
cheatcode stage and that the codes did what they claim:

    ./tests/linuxrc/boot-test.sh            # uses trixie/isodata
    ./tests/linuxrc/boot-test.sh path/to/isodata

The guest reports over the serial port rather than to the screen. That matters
for more than convenience: serial records *when* something happened, so the
test can assert `pgrep -c Xorg` is 0 at the moment `cliexec=` runs, which is
what proves those commands are ordered before X rather than racing it. A
screenshot can only show what is on screen when you happen to look.

Two stages are timed, with budgets in seconds from power-on:

| Stage | Measured | Budget |
| --- | --- | --- |
| `cliexec=` reached | 85-110s | 180s (`CLI_TIMEOUT`) |
| `guiexec=` reached | ~145s | 240s (`GUI_TIMEOUT`) |

The measurements are from an emulated host with no KVM and a `base_only` boot;
the budgets leave headroom for a slower machine or a fuller module set, and
both can be raised through those environment variables.

One boot covers every cheatcode. By the time `cliexec=` runs, everything the
initrd wrote is on disk, and `zram=` and `volume=` have already run; only
`guiexec=` needs a desktop session, and that arrives about 35 seconds later.
An earlier figure of "20 minutes to test the GUI" was an artefact of watching
screenshots until the wallpaper and conky had finished painting, long after
the session autostart had already run the commands.

If you are iterating on `linuxrc` alone, there is no need to rebuild the whole
image: unpack `initrd1.xz`, replace the script, repack, and rebuild only the
ISO. A full `build-trixie` run is around 25 minutes even with a warm apt
cache, dominated by package installation and squashfs compression.

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

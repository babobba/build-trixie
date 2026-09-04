# Where the boot time goes

`tests/linuxrc/boot-profile.sh` boots the image once with every stage
stamped from `/proc/uptime` and prints a timeline. It exists because the
boot is invisible to the clock by default: linuxrc silences printk in its
second line, so from "Run /init" to the first init message nothing on the
serial log carries a time.

## Running it

```
sudo ./tests/linuxrc/boot-profile.sh                      # coarse: linuxrc stages, systemd, desktop
sudo PROF_FINE=1 ./tests/linuxrc/boot-profile.sh          # plus every modprobe, every init script, the login scripts
sudo PROF_STRACE=1 ./tests/linuxrc/boot-profile.sh        # plus an strace of the X session and the X server
sudo PROF_STRACE=openbox ./tests/linuxrc/boot-profile.sh  # every syscall of openbox alone, with time per syscall
sudo PROF_ROOTCOPY=/some/tree ./tests/linuxrc/boot-profile.sh   # measure a rootfs change before the rebuild that ships it
```

It repacks the initrd from `initrd-src` exactly as the boot tests do, then
instruments a scratch copy: every `echo $i"..."` stage line becomes a
stamped one, and extra stamps bracket the silent blocks. Nothing in the
repository is modified. Inside the guest the desktop hook runs
`systemd-analyze time`, `blame` and `critical-chain`, reads the process
start times of the X and desktop programs (which systemd knows nothing
about), and prints who consumed CPU.

In fine mode two hook files go in through rootcopy:
`/lib/lsb/init-functions.d/00-boot-profile` and `/etc/lsb-base-logging.sh`.
Every init script sources init-functions, so each script stamps its own
begin and exit and each message it logs; that is how the sysvinit rc phase
is seen script by script. The first scripts run before `/proc` and `/dev`
exist, so those stamps fall back to the wall clock and a file on the root,
and the report prints them aligned.

`PROF_ROOTCOPY` copies a tree over the union at boot, the way the initrd
has always offered. A systemd drop-in, a changed `/etc/profile`, a stamp
file: all measurable in four minutes instead of the rebuild that would ship
them. The harness dates its own rootcopy directories in the past so the
union's `/usr` keeps an old mtime; otherwise ldconfig runs on every test
boot and the image looks like one that ships without the update-done stamp.

## Reading the numbers

Everything measured in this repository so far ran under QEMU without KVM.
A host benchmark put that at about six times slower than the same CPU-bound
work on hardware, so divide CPU-bound phases by roughly six. Sleeps and
timeouts do not shrink. That distinction was the main finding.

Run-to-run noise is about two seconds either way. A change expected to save
less than that will not show in one run; the boot tests' cliexec times
across a whole run of `boot-test-all.sh` are a steadier signal than any
single profile.

## What was found, and what was done

Guest seconds under emulation, systemd image, before and after this work:

| Phase | Before | After | What changed |
|---|---|---|---|
| Boot menu, before the kernel | ~16 (host) | ~9 | isolinux `timeout 70` was 7 s of waiting |
| Kernel unpacking the initrd | 7.4 | 1.2 | 15 MB xz of 360 modules, 52 MB of it datacentre NICs, to 10 MB zstd of 308; modprobe index prebuilt |
| Module loading in the initrd | 16.4 | ~7 | 111 modprobes by list to a short list plus drivers from the hardware's modaliases; the first modprobe no longer scans every module |
| Initrd handoff | 31.7 | 15 | the above, plus no ata unload loop |
| systemd userspace to graphical | 21.4 | 13.6 | ldconfig no longer runs every boot (update-done stamp at build); the login prompt no longer waits for the network |
| login to startx | 9.6 | 6 | `sleep 3` in /etc/profile removed |
| openbox to its autostart | 11.6 | 11.6 | attributed, not changed: openbox waits on the X server, which is software-rendering under emulation |
| autostart to the desktop scripts | 8.6 | 1.5 | `sleep 8` replaced by a wait for pcmanfm's window |
| Desktop autostart reached | 92 | 62 | |

Fixed sleeps removed in total: 20 seconds on every boot, on any hardware.

The sysvinit image's rc phase is a chain of about twenty scripts run one
after another by their dependencies, each costing about 0.3 s to start under
emulation. checkroot.sh was 6.9 of its 35 seconds with nothing to do on an
overlay root and is disabled at build time; so are checkfs, the cryptdisks
pair and two of three bootclean runs. The head of that boot, before udev's
first message, is init 0.9, rc's own startup 1.9, mountkernfs 1.8 and the
udev script's preamble 3.1; standard Debian, nothing to fix.

Two things the profiler found that were not speed at all: the initrd had
no `/sbin/modprobe`, so the kernel could never autoload a module there
(ext4 needs crc32c, FAT needs nls tables, dm-crypt needs xts); and a first
fix for that repointed the kernel at `/bin/modprobe` through a sysctl that
survived the pivot, which broke every kernel-requested module load on the
running system until the UEFI test noticed efivars missing.

## What is left

Under emulation the remaining time is the X server's software rendering
and systemd's own startup; on hardware both should be small. The number
that matters most is the one not measured yet: a real machine, booted from
a USB stick, with the profiler writing its stamps to the medium instead of
a serial port. That is a ten-line change to the profiler and a stick.

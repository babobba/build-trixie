# Evaluating MiniOS

This branch is an evaluation, not a change to the builder. Nothing here alters
`build-trixie` or the Devuan image; it exists to answer one question — does
MiniOS build and run in its default state — before deciding whether any of its
approach is worth adopting.

## Why MiniOS

Our own image is Devuan 6 excalibur: sysvinit, no systemd. That is not an
accident of taste, it follows from the initrd. `initrd-src/linuxrc` descends
from Porteus, and the Porteus lineage has always assumed a traditional init —
our `login=`, `nologin`, `cliexec=` and `guiexec=` cheatcodes all work by
editing `/etc/inittab` and `/etc/profile`.

MiniOS is the counter-example: **Debian 13 trixie, systemd as PID 1, and a
Porteus-ancestor shell-script initrd**. It descends from Tomáš Matejíček's
Linux Live Kit, the common ancestor of both Slax and Porteus, and unlike
Porteus and PorteuX it publishes its initrd as readable source.

The mechanism it uses to make the two coexist is small. LiveKit's
`change_root()` ends with:

    pivot_root . run/initramfs
    exec $CHROOT . $INIT </dev/console >/dev/console 2>&1

`$INIT` is whatever `/sbin/init` resolves to, which on Debian is systemd — so
the shell script simply execs it. Our `linuxrc` already hands off the same way.
The difference is *where* it pivots: Porteus moves the old root to `/mnt/live`,
LiveKit moves it to `/run/initramfs`, which is where systemd looks at shutdown,
and drops a `shutdown` script there for systemd to run.

## What "default state" means here

`linux-live/build.conf` as shipped, unmodified:

| Setting | Value |
| --- | --- |
| `DISTRIBUTION` | `trixie` |
| `DISTRIBUTION_ARCH` | `amd64` |
| `DESKTOP_ENVIRONMENT` | `xfce` |
| `PACKAGE_VARIANT` | `standard` |
| `COMP_TYPE` | `zstd` |
| `INITRAMFS_BUILDER` | `livekit` |
| `BOOTLOADER` | `syslinux-native` |
| `DEFAULT_TARGET` | `graphical.target` |

## Building it here

    ./minios/build-minios

Upstream is not vendored. The script clones `minios-linux/minios-live`, applies
the environment fixes below, and runs the stock build.

### Environment fixes, and why each is needed

None of these change what MiniOS produces. They exist because this build
container reaches the network through an agent proxy that serves **only HTTPS
CONNECT** — plain `http://` returns 403.

1. **Mirrors rewritten `http:` → `https:`.** MiniOS ships `http://` URLs for
   `deb.debian.org` and `deb.minios.dev`. Both hosts serve HTTPS fine; it is
   only the scheme in the config that has to change.

2. **`sudo` must preserve the proxy environment.** This one is not obvious and
   cost a failed run. `minioslib` invokes debootstrap as

       sudo DEBIAN_FRONTEND="noninteractive" debootstrap ...

   with no `-E`, so sudo strips `https_proxy` and `CURL_CA_BUNDLE` and
   debootstrap fails with `Failed getting release file` — while `curl` fetches
   the very same URL successfully, which makes it look like a mirror problem
   rather than an environment one. Fixed with a sudoers `env_keep` rather than
   by patching MiniOS, so the upstream tree stays stock.

3. **Host prerequisites.** `mtools rsync grub-common lz4 zstd gettext` plus
   syslinux/grub bits. `linux-live/prerequisites.list` names most of these;
   `gettext` is missing from it and only shows up as noisy
   `gettext: command not found` warnings rather than a hard failure.

4. **`deb.minios.dev` must be reachable.** About twenty `minios-*` packages
   come from it — `minios-boot`, `minios-initramfs`, `minios-live-config`,
   `minios-svc` and friends, which are the live-boot machinery itself. The
   build cannot produce MiniOS without them, and the key fetch uses
   `curl --fail`, so it stops rather than degrading.

### One upstream defect, not an environment problem

The stock build **does not complete** on trixie. Four out-of-tree Realtek
wireless drivers fail to compile against Debian trixie's 6.12 kernel:

    realtek-rtl8821au-dkms  realtek-rtl88xxau-dkms
    realtek-rtl8188eus-dkms realtek-rtl8814au-dkms

The first error is representative:

    ioctl_cfg80211.c:10523:32: error: initialization of
    'int (*)(struct wiphy *, struct net_device *, struct cfg80211_chan_def *)'
    from incompatible pointer type
    'int (*)(struct wiphy *, struct cfg80211_chan_def *)'
    [-Wincompatible-pointer-types]

cfg80211's `set_monitor_channel` gained a `struct net_device *` parameter, the
drivers were never updated, and GCC 14 treats an incompatible function-pointer
assignment as an error rather than a warning. dpkg then fails to configure
those four packages plus `linux-headers-*`, and the build stops before
producing an ISO.

This is upstream's, not ours. It has nothing to do with the proxy, and the
same source would fail on any trixie host. It also looks like an oversight
rather than a decision: `linux-live/environments/xfce/01-kernel/packages.list`
already excludes five sibling drivers from trixie —

    realtek-rtl8723cs-dkms  -d=trixie ...
    realtek-rtl8821cu-dkms  -d=trixie -d=excalibur -d=sid
    realtek-rtl8821ce-dkms  -d=trixie -d=excalibur -d=sid
    realtek-rtl88x2bu-dkms  -d=bookworm -d=daedalus -d=trixie ...

— so the mechanism for skipping a driver that no longer builds is already in
use, three lines above the four that were missed.

`build-minios` therefore adds `-d=trixie` to those four, which is upstream's
own idiom applied to the packages it had not caught up with yet. **That is a
deviation from the shipped configuration**, and the only one that changes what
gets installed. Everything the resulting image does is otherwise stock; the
drivers in question are for USB Realtek wifi adapters, which a virtual machine
does not have.

`KERNEL_BUILD_DKMS="false"` looks like the tidier switch but is not: the
realtek entries carry no `+kbd=` condition, so that variable only gates whether
kernel headers get installed, not whether these packages do.

### And one that is purely local

`firmware-b43-installer` does not ship firmware — its postinst downloads a
tarball from `github.com`. Behind this proxy, `wget` inside the chroot fails
with

    ERROR: The certificate of 'github.com' is not trusted.

because the chroot's trust store has no copy of the proxy's CA. Unlike the
Realtek failure this says nothing about MiniOS; on a host with direct internet
the package installs normally.

`build-minios` excludes it, and only when a proxy is configured. The
alternative — installing the proxy CA into the chroot — was rejected on
purpose: the CA would be baked into the `00-core` module and ship inside the
ISO, leaving a MITM certificate trusted by every machine that boots it. That is
not a reasonable price for firmware for Broadcom b43 chips that a virtual
machine does not have.

## Checking that it runs

    ./tests/minios/boot-test-minios.sh

Boots the produced ISO under QEMU and confirms it reaches a graphical session.
MiniOS's default boot line carries no `console=ttyS0`, and adding one would
stop it being the default state, so this test reads the framebuffer through the
QEMU monitor instead of the serial port.

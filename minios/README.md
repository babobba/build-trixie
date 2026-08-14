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

## Checking that it runs

    ./tests/minios/boot-test-minios.sh

Boots the produced ISO under QEMU and confirms it reaches a graphical session.
MiniOS's default boot line carries no `console=ttyS0`, and adding one would
stop it being the default state, so this test reads the framebuffer through the
QEMU monitor instead of the serial port.

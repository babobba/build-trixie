# The first successful MiniOS build

The exact set of changes applied to upstream `minios-live` to get an ISO out of
it here, captured as a patch so the result is reproducible rather than
described. `minios/build-minios` applies the same edits with `sed`; this is the
record of what those edits actually produced.

    upstream:  minios-linux/minios-live @ 63cdc5a  ("Update boot menu artwork")
    produced:  minios-trixie-xfce-standard-amd64-20260814_0040.iso  (764 MB)
    result:    boots to an Xfce desktop, Debian 13 trixie, systemd 257 as PID 1

To reapply:

    cd /path/to/minios-live
    git checkout 63cdc5a
    git apply /path/to/minios-live-firstbuild.patch

## What is in the patch, and why

Three groups, worth keeping apart because only one of them says anything about
MiniOS.

### 1. Mirrors over https — environment

`aptsources/debian.list`, `aptsources/trixie.list`, `minioslib`, and
`build.conf`'s `CHECK_INTERNET_ADDRESS`. This container reaches the network
through a proxy that serves only HTTPS CONNECT, and plain `http://` returns
403. Both `deb.debian.org` and `deb.minios.dev` serve HTTPS, so only the scheme
changes; nothing about the produced image differs.

Not in the patch, because it is not a file change: `minioslib` runs
debootstrap as

    sudo DEBIAN_FRONTEND="noninteractive" debootstrap ...

with no `-E`, so sudo strips `https_proxy` and `CURL_CA_BUNDLE` and debootstrap
fails with `Failed getting release file` while `curl` fetches the same URL
successfully. `build-minios` fixes that with a sudoers `env_keep` so the
upstream tree stays stock.

### 2. Four Realtek DKMS drivers excluded — upstream

`scripts/01-kernel/packages.list`. This is the one real defect, and it is not
specific to this environment: the same source fails on any trixie host.

    realtek-rtl8821au-dkms  realtek-rtl88xxau-dkms
    realtek-rtl8188eus-dkms realtek-rtl8814au-dkms

fail to compile against Debian trixie's 6.12 kernel:

    ioctl_cfg80211.c:10523:32: error: initialization of
    'int (*)(struct wiphy *, struct net_device *, struct cfg80211_chan_def *)'
    from incompatible pointer type
    'int (*)(struct wiphy *, struct cfg80211_chan_def *)'
    [-Wincompatible-pointer-types]

cfg80211's `set_monitor_channel` gained a `struct net_device *`, the drivers
were never updated, and GCC 14 treats the mismatch as an error rather than a
warning. dpkg then fails to configure those four plus `linux-headers-*` and the
build stops with no ISO.

The fix is upstream's own idiom: five sibling Realtek drivers in the same file
already carry `-d=trixie`, three lines above the four that were missed, so this
adds the same exclusion to those four. `broadcom-sta-dkms` still builds and
installs `wl.ko`, so the exclusion is scoped to what is actually broken.

`KERNEL_BUILD_DKMS="false"` is not the equivalent switch — these entries carry
no `+kbd=` condition, so that variable gates only whether kernel headers are
installed, not whether these packages are.

Note the path: `environments/xfce/01-kernel` is a symlink to
`scripts/01-kernel`, so an edit through either path lands in the same file.

### 3. firmware-b43-installer excluded — environment

`scripts/02-firmware/packages.list`. The package ships no firmware; its postinst
downloads a tarball from `github.com`, and `wget` inside the chroot has no copy
of the proxy's CA:

    ERROR: The certificate of 'github.com' is not trusted.

Nothing to do with MiniOS — it installs normally with direct internet.

Installing the proxy CA into the chroot would also have fixed this and was
deliberately not done: the CA would be baked into the `00-core` module and ship
inside the ISO, leaving a MITM certificate trusted by every machine that boots
it. Firmware for Broadcom b43 chips that a virtual machine does not have is not
worth that.

## Not in the patch

`linux-live/condinapt` lost its executable bit during the build (100755 →
100644). That was an accident of the build, not a change anyone made on
purpose, so it is restored rather than recorded.

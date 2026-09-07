# Every config through every check

Result of `tools/check-configs` over the sysvinit configs, 6 September 2026,
built from a snapshot of the trixie-sysvinit branch at 6e44387 under
emulation (no KVM on the build host). Each config was built, then put
through the image tests, the initrd test, the programs boot test and the
GUI boot test. What the first runs found and what was fixed is in the
commit history of the two days before; this is the state after the fixes.

Times are per step in seconds; with the next config building while the
current one's tests run, the six larger configs took 103 minutes of wall
clock, where the same six had taken 187 the day before one after the
other. On a host with KVM the guest steps are several times shorter again.

| Config | Build | Image | Initrd | Programs | GUI | Total |
|---|---|---|---|---|---|---|
| default-pxe | ok 308 | ok 49 | ok 2 | ok 237 | ok 318 | 914 |
| jwm | ok 288 | ok 50 | ok 2 | ok 173 | ok 293 | 806 |
| default | ok 214 | ok 40 | ok 2 | ok 201 | ok 313 | 770 |
| mate | ok 310 | ok 54 | ok 2 | ok 210 | ok 273 | 849 |
| lxqt | ok 325 | FAIL 58 | ok 2 | ok 220 | ok 366 | 971 |
| obdog | ok 344 | FAIL 80 | ok 2 | ok 431 | FAIL 942 | 1799 |
| tint2 | ok 418 | FAIL 80 | ok 2 | ok 427 | FAIL 963 | 1890 |
| ddog | ok 417 | FAIL 77 | ok 2 | ok 342 | FAIL 921 | 1759 |


| Config | Result | What remains |
|---|---|---|
| default, default-pxe, jwm, mate | green | |
| lxqt | one script call | apt-trim calls `rm_func`, which nothing defines |
| obdog | six script calls, xlunch | see below |
| tint2 | seven script calls, xlunch | see below, plus ob-desktop runs cairo-dock, not installed |
| ddog | five script calls, xlunch | see below |
| lxqt-full, chromedog | not built here | they install Google Chrome, and the build sandbox's egress proxy denies dl.google.com (CONNECT answered 403, checked again on 7 September over ten minutes); nothing else is known to be wrong with them. What the last attempt did show: the overlay's Chrome entry was plain http, which apt in the chroot fetched directly and lost at DNS while every Debian archive went through the HTTPS proxy; the entry is https now, so the next attempt reaches Google the way it reaches Debian |
| *-xlibre (ten) | cannot build | the `xserver-xlibre-*` and `xlibre` packages are in no repository the build knows |

Findings that remain on obdog, tint2 and ddog, all in scripts from the
DebianDog packages rather than in this build:

- `add-apt-repository` uses `apt-key`, which trixie no longer ships.
- `apt-trim` calls `rm_func`, a function nothing defines.
- `camphonetab` offers an iPhone choice that runs `idevicepair` and
  `ifuse`; neither libimobiledevice-utils nor ifuse is installed.
- `gentriesquick` calls `genentries`, which the xlunch package does not
  ship.
- `move-in-crypt` opens `xfe` afterwards; not installed (obdog only).
- `xlunch` exits 64 on this image whatever it is given, so the xluncher
  menus and xlunch-logout produce no window. Reproduced outside the guest
  against a virtual X server, with and without a font, background or
  entries file; not diagnosed further.

Each is either a package to add to the config (cairo-dock, xfe,
libimobiledevice-utils and ifuse), a script to fix upstream, or a thing to
accept and list as optional in `tests/image/test_executables.sh`. That is
a decision for the maintainer; until it is made these configs stay red on
exactly these lines.

Two more things the batch showed that are not defects of any one config:
the dog-boot overlay puts Google's Chrome repository into every image's
apt sources, whether or not the config installs Chrome; and the DebianDog
repository rebuilds thunar under Debian's name at an epoch of its own, so
that build is what every config gets.

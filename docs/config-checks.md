# Every config through every check

Result of `tools/check-configs` over the sysvinit configs, 5 September 2026,
built from the trixie-sysvinit branch at 51b3ab6. Each config was built,
then put through the image tests, the initrd test, the programs boot test
and the GUI boot test. What the first runs found and what was fixed is in
the commit history of that day; this is the state after the fixes.

| Config | Result | What remains |
|---|---|---|
| default | green | |
| default-pxe | green | |
| jwm | green | |
| mate | green | |
| lxqt | one script call | apt-trim calls `rm_func`, which nothing defines |
| obdog | six script calls, xlunch | see below |
| tint2 | seven script calls, xlunch | see below, plus ob-desktop runs cairo-dock, not installed |
| ddog | five script calls, xlunch | see below |
| lxqt-full, chromedog | not built here | they install Google Chrome, and dl.google.com is unreachable from the build sandbox; nothing else is known to be wrong with them |
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

#!/bin/sh
# Do the files in the image still match what their packages installed?
#
# dpkg --verify compares every file against the md5sum recorded at install
# time. On this image it reports about 14,000 differences, which sounds alarming
# and is almost entirely the build deliberately deleting documentation and
# translations to shrink the squashfs. The useful signal is what is left after
# those are set aside:
#
#   - files whose *contents* changed after the package installed them, and
#   - files reported missing from somewhere other than the stripped trees.
#
# Both are listed explicitly below. Anything outside those lists is a file that
# changed without anyone writing down why, which is the thing worth catching:
# it means the image no longer matches its package metadata, so an upgrade of
# that package will either revert the change or prompt about a conffile nobody
# remembers editing.
. "$(dirname "$0")/lib.sh"
mount_image "$@"

command -v dpkg >/dev/null || skip "dpkg not installed on the build host"
[ -f "$ROOT/var/lib/dpkg/status" ] || skip "no dpkg database in the image"

dpkg --root="$ROOT" --verify > "$WORK/verify" 2>"$WORK/verify.err" || true

echo "-- the check is actually running"
# dpkg --verify can only compare files it has md5sums for. If the build stripped
# /var/lib/dpkg/info the command would succeed while checking almost nothing, so
# the coverage is asserted before anything is concluded from the result.
NPKG=$(grep -c '^Package:' "$ROOT/var/lib/dpkg/status")
NSUM=$(ls "$ROOT"/var/lib/dpkg/info/*.md5sums 2>/dev/null | wc -l | tr -d ' ')
echo "   $NSUM of $NPKG packages carry md5sums"
[ "$NSUM" -gt $((NPKG / 2)) ] \
	&& _pass "most packages can be verified at all" \
	|| _fail "most packages can be verified at all" "only $NSUM of $NPKG have md5sums"

echo "-- packages are in a coherent state"
dpkg --root="$ROOT" --audit > "$WORK/audit" 2>&1 || true
assert_equal "dpkg --audit reports nothing" "" "$(cat "$WORK/audit")"
# "deinstall ok config-files" is a removed package whose conffiles remain. That
# is the normal end state after swapping init systems - the Debian/systemd image
# carries initscripts, insserv and sysv-rc in exactly that state because
# systemd-sysv displaced them - and it is not a broken install. Only genuinely
# incomplete states matter here: half-installed, unpacked, half-configured,
# triggers-pending.
BADSTATE=$(awk '/^Package:/{p=$2}
	/^Status:/{ if ($0 !~ /install ok installed/ && $0 !~ /deinstall ok config-files/) print p }' \
	"$ROOT/var/lib/dpkg/status" | tr '\n' ' ')
assert_empty "no package is left half-installed" "$BADSTATE"
# The exclusion must not be a blanket one: a package stuck half-configured has
# to still fail, so check the pattern only tolerates the removed-with-conffiles
# state.
assert_equal "the tolerated state is only 'deinstall ok config-files'" "" \
	"$(awk '/^Status:/{if ($0 ~ /half-installed|half-configured|unpacked|triggers-pending/) print}' \
		"$ROOT/var/lib/dpkg/status" | head -1)"

echo "-- deleted files are only in the trees the build strips"
# The build removes documentation, manual pages, locales and info files. Those
# deletions are expected; a deletion anywhere else is not.
# The udev vendor-name tables (20-OUI, 20-pci-vendor-model, 20-usb-vendor-model
# and friends) are deleted as well and hwdb.bin rebuilt without them; that
# file is generated, not shipped, so only the tables show up here.
STRIPPED='^/usr/share/(doc|doc-base|man|info|locale|help|gnome/help|gtk-doc)/|^/usr/lib/udev/hwdb\.d/20-(OUI|pci-vendor-model|usb-vendor-model|bluetooth-vendor-product|acpi-vendor)\.hwdb$'
UNEXPECTED_MISSING=$(awk '$1=="missing"{print $NF}' "$WORK/verify" \
	| grep -Ev "$STRIPPED" | sort -u)
NMISS=$(awk '$1=="missing"' "$WORK/verify" | wc -l | tr -d ' ')
echo "   $NMISS files reported missing in total"
# /opt/tmp holds build scratch from a DebianDog package and is removed during
# cleaning; the package still lists it, so it shows up here.
UNEXPECTED_MISSING=$(echo "$UNEXPECTED_MISSING" | grep -v '^/opt/tmp' | tr '\n' ' ')
# A file another package's maintainer script removes on purpose (camphonetab
# drops libmtp's udev rule so mtp-probe stays off the phones it handles) is
# missing by design; the script that names it is the documentation.
UNEXPECTED_MISSING=$(for f in $UNEXPECTED_MISSING; do
	by=$(grep -lF "$(basename "$f")" "$ROOT"/var/lib/dpkg/info/*.postinst "$ROOT"/var/lib/dpkg/info/*.preinst 2>/dev/null | head -1)
	[ -n "$by" ] && { echo "   $f removed by $(basename "$by")" >&2; continue; }
	echo "$f"
done | tr '\n' ' ')
assert_empty "nothing is missing outside the stripped trees" "$UNEXPECTED_MISSING"

echo "-- files whose contents changed since their package installed them"
# Expected, with the reason each one is here:
#   /etc/skel/.profile          conffile, build sets the live user's environment
#   /etc/rc.local               conffile, the live system's startup hook
#   /etc/X11/app-defaults/XTerm conffile, build's terminal defaults
#   /etc/cryptsetup-initramfs/conf-hook  conffile, encrypted-changes support
#   /usr/share/pixmaps/debian-logo.png   rebranding
#   /usr/share/icons/hicolor/icon-theme.cache  regenerated by gtk-update-icon-cache
#   /etc/mke2fs.conf            conffile; the dog-boot overlay ships e2fsprogs
#                               1.42-era defaults (uninit_bg, no metadata_csum
#                               or 64bit) that the save-file tools format with.
#                               Whether to keep them is an open question; until
#                               it is answered the change is a known one.
#   /etc/menu-methods/jwm       conffile of jwm; jwmconf's postinst copies its
#                               own over it so the dog menu is generated
KNOWN_CHANGED="
/etc/menu-methods/jwm
/etc/mke2fs.conf
/etc/skel/.profile
/etc/rc.local
/etc/X11/app-defaults/XTerm
/etc/cryptsetup-initramfs/conf-hook
/usr/share/pixmaps/debian-logo.png
/usr/share/icons/hicolor/icon-theme.cache
"
CHANGED=$(awk '$1!="missing"{print $NF}' "$WORK/verify" | sort -u)
# Three more kinds of change explain themselves from the image:
#  - a dpkg diversion (live-tools diverts update-initramfs): the file at the
#    path is another package's by design;
#  - a file another package's maintainer script edits (lxinputsave rewrites
#    lxinput.desktop): the script that names it is the documentation;
#  - a file of a hand-built package, one whose Maintainer field carries no
#    address (fredx181, root@wheezy, rcrsn51 - the DebianDog packages): their
#    md5sums are what did not keep up with their files, not the image.
#  - a package the DebianDog repository builds under Debian's own name and
#    maintainer, at a version of its own (thunar 1:4.20.2-2 over Debian's
#    4.20.2-1): a rebuild whose md5sums record did not keep up either. The
#    repository's index says which versions are its; it is fetched once per
#    run, and without a network this rule simply does not apply.
DOG_INDEX="$WORK/dog-Packages"
DOG_URL=$(sed -n 's/^export REPOS64=.*\(https:[^ ]*\) .*/\1Packages/p' "$REPO/build-trixie" | head -1)
[ -n "$DOG_URL" ] && curl -sSL --max-time 30 -o "$DOG_INDEX" "$DOG_URL" 2>/dev/null || : > "$DOG_INDEX"
dog_build() {  # PACKAGE -> 0 when the installed version is one the DebianDog index lists
	v=$(awk -v p="$1" 'BEGIN{RS=""} $1=="Package:" && $2==p { if (match($0, /\nVersion: [^\n]*/)) print substr($0, RSTART+10, RLENGTH-10); exit }' "$ROOT/var/lib/dpkg/status")
	[ -n "$v" ] && awk -v p="$1" -v v="$v" 'BEGIN{RS=""; f=1} $1=="Package:" && $2==p && index($0, "\nVersion: " v "\n") { f=0; exit } END{exit f}' "$DOG_INDEX" 2>/dev/null
}
DIVERTED=$(awk 'NR % 3 == 1' "$ROOT/var/lib/dpkg/diversions" 2>/dev/null)
owner_of() {   # FILE -> package name, from the .list files
	grep -lx -- "$1" "$ROOT"/var/lib/dpkg/info/*.list 2>/dev/null | head -1 | sed 's|.*/||; s/\.list$//; s/:amd64$//'
}
handbuilt() {  # PACKAGE -> 0 when its Maintainer has no <address>
	awk -v p="$1" 'BEGIN{RS=""} $1=="Package:" && $2==p { m=""; if (match($0, /Maintainer: [^\n]*/)) m=substr($0, RSTART, RLENGTH); exit !(m !~ /</) }' "$ROOT/var/lib/dpkg/status"
}
#  - a file the build copies over the packages' from an overlay in the repo:
#    dog-boot-trixie-* for every image, modules-trixie/DESKTOP for the
#    desktop the config names (xfce4's menu). The overlay is the documentation.
overlay_has() {   # FILE -> 0 when an overlay in the repo ships it
	for o in "$REPO"/dog-boot-trixie-* "$REPO"/modules-trixie/*; do
		[ -e "$o$1" ] && { echo "${o#$REPO/}"; return 0; }
	done
	return 1
}
UNEXPECTED_CHANGED=""
for f in $CHANGED; do
	echo "$KNOWN_CHANGED" | grep -qx -- "$f" && continue
	echo "$DIVERTED" | grep -qx -- "$f" && { echo "   $f is diverted"; continue; }
	o=$(overlay_has "$f") && { echo "   $f is shipped by $o"; continue; }
	by=$(grep -lF "$(basename "$f")" "$ROOT"/var/lib/dpkg/info/*.postinst "$ROOT"/var/lib/dpkg/info/*.preinst 2>/dev/null | grep -v "/$(owner_of "$f")\." | head -1)
	[ -n "$by" ] && { echo "   $f edited by $(basename "$by")"; continue; }
	pkg=$(owner_of "$f")
	[ -n "$pkg" ] && handbuilt "$pkg" && { echo "   $f belongs to $pkg, a hand-built package"; continue; }
	[ -n "$pkg" ] && dog_build "$pkg" && { echo "   $f belongs to $pkg, a DebianDog build"; continue; }
	UNEXPECTED_CHANGED="$UNEXPECTED_CHANGED $f"
done
# The Devuan archive keyrings used to appear here. The dog-boot overlay carried
# 2024 copies of devuan-archive-keyring, devuan-keyring and devuan-removed-keys,
# and `cp -af ../dog-boot-trixie-20240602/* chroot/` wrote them through the
# .gpg -> .pgp symlinks over the files the devuan-keyring package installed -
# leaving the image verifying Devuan signatures against six keys where the
# package ships eight. Those three overlay files are gone, so a keyring in this
# list is now a real regression rather than a known one.
assert_empty "no undocumented content change" "$(echo $UNEXPECTED_CHANGED)"

echo "-- and the list of expected changes has not gone stale"
# an entry for a file this config does not install (jwm's menu method on an
# openbox image) is neither stale nor checkable here
for f in $KNOWN_CHANGED; do
	[ -e "$ROOT$f" ] || continue
	echo "$CHANGED" | grep -qx -- "$f" \
		|| _fail "$f is still listed as changed" "it no longer differs - drop it from the list"
done
_pass "every documented change is still present"

finish

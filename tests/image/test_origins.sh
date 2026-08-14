#!/bin/sh
# Where did the packages in this image come from?
#
# The image is assembled from five archives at once: Debian trixie (plus
# -updates and -security), Devuan excalibur, the DebianDog repository, an
# xlibre repository, and a frozen snapshot.debian.org from August 2024. That
# mix is the point - Devuan is where sysvinit and the de-systemd'd forks come
# from - but it is also the thing most likely to go wrong quietly.
#
# Two failure modes are worth catching:
#
#   1. A package silently changing sides. Devuan forks a specific set of
#      packages, mostly init, udev, polkit and their libraries. If one of those
#      comes from Debian instead, the image gets a systemd-linked build; if a
#      new one appears on the Devuan side, something pulled in a fork nobody
#      asked for. The reviewed set is listed below, so either direction fails.
#
#   2. The pinning that keeps (1) true being removed or weakened. Without
#      /etc/apt/preferences.d/99devuan the Devuan packages lose to Debian's
#      higher version numbers on the next apt upgrade.
#
# apt's own lists are stripped from the image, so origin is read from the dpkg
# database: Devuan rebuilds carry "devuan" in the version and a @lists.dyne.org
# maintainer.
. "$(dirname "$0")/lib.sh"
mount_image "$@"

STATUS="$ROOT/var/lib/dpkg/status"
[ -f "$STATUS" ] || skip "no dpkg database in the image"

# Which image is this? The repo builds two, and they are meant to be different
# systems - configs-trixie/default.conf gives Devuan with sysvinit,
# default-systemd.conf gives Debian with systemd. Asserting Devuan-ness against
# the systemd image fails ten checks for the entirely wrong reason, so the
# distribution decides which set of assertions applies.
#
# Read from the image rather than passed in, so the test cannot be pointed at
# the wrong expectations.
DISTRO_ID=$(sed -n 's/^ID=//p' "$ROOT/etc/os-release" 2>/dev/null | tr -d '"')
echo "   image reports ID=$DISTRO_ID"

if [ "$DISTRO_ID" != devuan ]; then
	echo "-- this is the Debian/systemd image"
	assert_equal "os-release says debian" "debian" "$DISTRO_ID"
	assert_file "systemd is installed" "$ROOT/lib/systemd/systemd"
	assert_symlink "/sbin/init points at it" "$ROOT/sbin/init" "../lib/systemd/systemd"

	echo "-- and carries none of the Devuan apparatus"
	NDEV=$(awk '/^Package:/{p=$2} /^Version:/{if ($2 ~ /devuan/) print p}' "$STATUS" | wc -l)
	assert_equal "no Devuan-versioned packages" "0" "$(echo $NDEV)"
	assert_no_file "no 99devuan pin"  "$ROOT/etc/apt/preferences.d/99devuan"
	# 00systemd pins systemd to -1; it is what keeps systemd out of the Devuan
	# build, so its presence here would be a contradiction rather than a
	# leftover.
	assert_no_file "no 00systemd pin" "$ROOT/etc/apt/preferences.d/00systemd"
	assert_equal "sysvinit-core is not installed" "" \
		"$(awk '/^Package: sysvinit-core$/{f=1} f&&/^Status:/{print;exit}' "$STATUS" | grep 'ok installed')"

	echo "-- the archives it was built from"
	SRC="$ROOT/etc/apt/sources.list"
	assert_file "sources.list exists" "$SRC"
	assert_equal "every archive is reached over https" "" \
		"$(grep -E '^[[:space:]]*deb ' "$SRC" | grep -v 'https://' | tr '\n' ' ')"
	assert_equal "no Devuan repository" "" \
		"$(grep -c 'devuan' "$SRC" | grep -v '^0$')"
	# A repository whose key never arrived breaks apt update forever. The build
	# skips such an entry rather than writing it; this is the check that it did.
	BADSRC=""
	for f in "$ROOT"/etc/apt/sources.list.d/*.sources "$ROOT"/etc/apt/sources.list.d/*.list; do
		[ -f "$f" ] || continue
		k=$(sed -n 's/^Signed-By: *//p;s/.*signed-by=\([^]]*\).*/\1/p' "$f" | head -1)
		[ -n "$k" ] && [ ! -s "$ROOT$k" ] && BADSRC="$BADSRC $(basename "$f")"
	done
	assert_empty "no repository with a missing keyring" "$BADSRC"

	finish
	exit
fi

echo "-- this is the Devuan/sysvinit image"

# ------------------------------------------------------- classify by origin

# Two independent signals, because neither is complete on its own. Most Devuan
# rebuilds carry "devuan" in the version, but eudev and libeudev1 are Devuan's
# own software rather than forks of a Debian package, so they use upstream
# versions; and several Devuan developers list a personal maintainer address
# rather than the team's.
devuan_versioned() {
	awk '/^Package:/{p=$2} /^Version:/{if ($2 ~ /devuan/) print p}' "$STATUS" | sort -u
}
devuan_maintained() {
	awk '/^Package:/{p=$2} /^Maintainer:.*dyne\.org/{print p}' "$STATUS" | sort -u
}

devuan_versioned  > "$WORK/by-version"
devuan_maintained > "$WORK/by-maintainer"
sort -u "$WORK/by-version" "$WORK/by-maintainer" > "$WORK/devuan"
NPKG=$(grep -c '^Package:' "$STATUS")
NVER=$(wc -l < "$WORK/by-version" | tr -d ' ')
NDEV=$(wc -l < "$WORK/devuan" | tr -d ' ')
echo "   $NPKG packages installed, $NDEV from Devuan ($NVER by version)"

echo "-- the classification works at all"
# If a signal came back empty the comparisons below would pass by comparing
# nothing against nothing.
[ "$NVER" -gt 10 ] && _pass "the version signal finds packages" \
	|| _fail "the version signal finds packages" "only $NVER - has the convention changed?"
[ "$(wc -l < "$WORK/by-maintainer" | tr -d ' ')" -gt 10 ] \
	&& _pass "the maintainer signal finds packages" \
	|| _fail "the maintainer signal finds packages" "too few"
[ "$NDEV" -lt "$NPKG" ] && _pass "and not everything is called Devuan" \
	|| _fail "and not everything is called Devuan" "all $NPKG matched"
assert_equal "the image is the Devuan derivative it claims to be" "devuan" \
	"$(sed -n 's/^ID=//p' "$ROOT/etc/os-release" 2>/dev/null)"

echo "-- where the two signals disagree, it is for a known reason"
# devuan-keyring, eudev and libeudev1: Devuan's own packages, upstream versions.
# apt*, isolinux: Devuan rebuilds whose maintainer is a person, not the team.
ONLY_MNT_OK=" devuan-keyring eudev libeudev1 "
ONLY_VER_OK=" apt apt-transport-https apt-utils isolinux libapt-pkg7.0 "
BAD=""
for p in $(comm -13 "$WORK/by-version" "$WORK/by-maintainer"); do
	case "$ONLY_MNT_OK" in *" $p "*) ;; *) BAD="$BAD $p" ;; esac
done
for p in $(comm -23 "$WORK/by-version" "$WORK/by-maintainer"); do
	case "$ONLY_VER_OK" in *" $p "*) ;; *) BAD="$BAD $p" ;; esac
done
assert_empty "no unexplained disagreement between the signals" "$BAD"

echo "-- the set of Devuan-sourced packages is the reviewed one"
# Reviewed 2026-08 against the built image. This is what the system takes from
# Devuan instead of Debian: sysvinit and its helpers, eudev in place of
# systemd-udev, the elogind-flavoured polkit, Devuan's apt, and the util-linux
# and coreutils rebuilds that drop systemd linkage. A change in either
# direction changes what the system is, so it wants a person to look at it
# rather than be absorbed silently.
EXPECTED="apt apt-transport-https apt-utils base-files bootlogd bsdutils
coreutils dbus dbus-bin dbus-daemon dbus-session-bus-common
dbus-system-bus-common dbus-x11 devuan-keyring eudev fdisk
init-system-helpers initscripts isolinux libapt-pkg7.0 libavahi-client3
libavahi-common-data libavahi-common3 libblkid1 libcolord2 libdbus-1-3
libeudev1 libfdisk1 liblastlog2-2 libmount1 libpcsclite1
libpolkit-agent-1-0 libpolkit-gobject-1-0 libpolkit-gobject-elogind-1-0
libproc2-0 libsmartcols1 libuuid1 login mount pkexec polkitd procps
sysv-rc sysvinit-core sysvinit-utils udev util-linux xserver-common
xserver-xorg-core xserver-xorg-legacy"

printf '%s\n' $EXPECTED | sort -u > "$WORK/expected"
NEW=$(comm -23 "$WORK/devuan" "$WORK/expected" | tr '\n' ' ')
GONE=$(comm -13 "$WORK/devuan" "$WORK/expected" | tr '\n' ' ')
assert_empty "no package newly taken from Devuan" "$NEW"
assert_empty "no package has stopped coming from Devuan" "$GONE"

echo "-- init really is sysvinit, not systemd"
# The reason the Devuan side exists. Checked directly rather than inferred from
# the package list.
assert_file "sysvinit provides /sbin/init" "$ROOT/sbin/init"
assert_equal "no systemd binary is installed" "" \
	"$(ls "$ROOT/lib/systemd/systemd" "$ROOT/usr/lib/systemd/systemd" 2>/dev/null)"

echo "-- the pinning that keeps Devuan winning is present"
PIN="$ROOT/etc/apt/preferences.d/99devuan"
assert_file "99devuan exists" "$PIN"
assert_equal "it pins the excalibur release" "yes" \
	"$(grep -q 'release *n=excalibur' "$PIN" 2>/dev/null && echo yes)"
PRIO=$(sed -n 's/^Pin-Priority: *//p' "$PIN" 2>/dev/null | sort -n | head -1)
# 1000 makes Devuan the preferred archive. Strictly above 1000 would also let
# apt downgrade to it; at exactly 1000 it will not, so a Debian package that
# ever sorts higher than the Devuan fork would win. That has not happened -
# the forks append to Debian's version rather than replacing it - but it is
# the reason this asserts the floor rather than treating 1000 as generous.
[ -n "$PRIO" ] && [ "$PRIO" -ge 1000 ] \
	&& _pass "at a priority that makes Devuan the preferred archive ($PRIO)" \
	|| _fail "at a priority that makes Devuan the preferred archive" "lowest is ${PRIO:-none}"

echo "-- systemd is held out by pinning too"
SPIN="$ROOT/etc/apt/preferences.d/00systemd"
assert_file "00systemd exists" "$SPIN"
assert_equal "it gives systemd a negative priority" "yes" \
	"$(grep -qE 'Pin-Priority: *-[0-9]' "$SPIN" 2>/dev/null && echo yes)"

echo "-- the archives the image is built from"
SRC="$ROOT/etc/apt/sources.list"
assert_file "sources.list exists" "$SRC"
assert_equal "every archive is reached over https" "" \
	"$(grep -E '^[[:space:]]*deb ' "$SRC" | grep -v 'https://' | tr '\n' ' ')"
# A frozen 2024 snapshot alongside a current trixie is a real hazard: anything
# resolved from it is two years stale and will never receive a security update.
# Recorded, not asserted away - it is there on purpose, for a package that is
# no longer in trixie.
xfail "no frozen snapshot archive is configured" \
	sh -c '! grep -q "snapshot.debian.org" "$1"' _ "$SRC"

finish

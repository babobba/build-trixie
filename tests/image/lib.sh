#!/bin/sh
# Shared harness for the image tests.
#
# These check the built root filesystem, not the boot scripts: whether the tree
# follows the FHS, whether files still match what their packages installed, and
# where the packages came from. They need a build to have happened, so they skip
# rather than fail when there is no image to look at.
#
# The image under test is 01-filesystem.squashfs, mounted read-only. Pass a
# directory instead to check an unpacked tree:
#
#     ./tests/image/test_fhs.sh /path/to/rootfs
#
# Nothing here writes to the image.

TESTDIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$TESTDIR/../.." && pwd)
ISODATA=${ISODATA:-$REPO/trixie/isodata}
SQUASH=${SQUASH:-$ISODATA/live/01-filesystem.squashfs}
WORK=${WORK:-/tmp/image-tests/$(basename "$0" .sh)}
RESULTS="$WORK/.results"

# The mountpoint deliberately lives OUTSIDE $WORK. An earlier version mounted
# the image at $WORK/root, and $WORK is wiped with rm -rf at every run - so a
# leftover mount from an interrupted run put the recursive delete inside the
# mounted image. It did no harm only because the mount is read-only, which is
# luck rather than design. Keeping the two apart removes the possibility.
MNT=${MNT:-/tmp/image-mnt-$(basename "$0" .sh)}

case "$WORK" in
	/|/tmp|"$HOME") echo "refusing to wipe $WORK"; exit 1 ;;
esac
rm -rf "$WORK"; mkdir -p "$WORK"; : > "$RESULTS"

skip() { echo "SKIP: $*"; exit 0; }

# ------------------------------------------------------------------ the image

IMG_MOUNTED=
mount_image() {
	if [ $# -ge 1 ] && [ -n "$1" ]; then
		[ -d "$1" ] || skip "no such directory: $1"
		ROOT=$1
		return
	fi
	[ -f "$SQUASH" ] || skip "no built image at $SQUASH - run build-trixie first"
	[ "$(id -u)" = 0 ] || skip "mounting the squashfs needs root"
	ROOT=$MNT
	# An interrupted earlier run can leave this mounted; reuse would silently
	# test a stale image.
	mountpoint -q "$ROOT" 2>/dev/null && umount "$ROOT" 2>/dev/null
	mkdir -p "$ROOT"
	mount -o loop,ro "$SQUASH" "$ROOT" 2>/dev/null || skip "could not mount $SQUASH"
	IMG_MOUNTED=1
	trap 'umount "$MNT" 2>/dev/null; rmdir "$MNT" 2>/dev/null' EXIT INT TERM
}

# The initrd is part of the image too, and some of what these tests care about
# is decided by the script inside it rather than by the tree on disk.
unpack_initrd() {
	IRD="$WORK/ird"
	[ -d "$IRD" ] && { echo "$IRD"; return 0; }
	[ -f "$ISODATA/live/initrd1.xz" ] || return 1
	command -v cpio >/dev/null || return 1
	mkdir -p "$IRD"
	( cd "$IRD" && xz -dc "$ISODATA/live/initrd1.xz" \
		| cpio -idm --quiet linuxrc finit 2>/dev/null )
	[ -f "$IRD/linuxrc" ] || return 1
	echo "$IRD"
}

# ---------------------------------------------------------------- assertions

_pass() { echo "  PASS  $1"; echo p >> "$RESULTS"; }
_fail() { echo "  FAIL  $1"; shift; [ $# -gt 0 ] && echo "        $*"; echo f >> "$RESULTS"; }

assert_equal() {       # DESC EXPECTED ACTUAL
	[ "$2" = "$3" ] && _pass "$1" || _fail "$1" "expected '$2', got '$3'"
}
assert_empty() {       # DESC ACTUAL   -- for list-shaped results
	if [ -z "$2" ]; then _pass "$1"
	else _fail "$1" "unexpected: $2"; fi
}
assert_dir()     { [ -d "$2" ] && _pass "$1" || _fail "$1" "missing directory ${2#$ROOT}"; }
assert_file()    { [ -f "$2" ] && _pass "$1" || _fail "$1" "missing file ${2#$ROOT}"; }
assert_symlink() {     # DESC LINK TARGET
	t=$(readlink "$2" 2>/dev/null)
	[ "$t" = "$3" ] && _pass "$1" || _fail "$1" "${2#$ROOT} -> '${t:-not a symlink}', wanted '$3'"
}
assert_mode()    {     # DESC PATH MODE
	m=$(stat -c '%a' "$2" 2>/dev/null)
	[ "$m" = "$3" ] && _pass "$1" || _fail "$1" "${2#$ROOT} is mode ${m:-absent}, wanted $3"
}

# A deviation we know about and have decided to live with for now. It does not
# fail the suite, but if it starts passing the suite does fail, so a marker
# cannot outlive the thing it documents.
xfail() {   # DESC CMD...
	desc=$1; shift
	if "$@" 2>/dev/null; then
		echo "  XPASS $desc"
		echo "        this now holds - turn the xfail into an assertion"
		echo f >> "$RESULTS"
	else
		echo "  xfail $desc"; echo x >> "$RESULTS"
	fi
}

# ------------------------------------------------------------------- summary

finish() {
	total=$(wc -l < "$RESULTS" | tr -d ' ')
	failed=$(grep -c f "$RESULTS" 2>/dev/null) || failed=0
	xfailed=$(grep -c x "$RESULTS" 2>/dev/null) || xfailed=0
	msg="  -- $(basename "$0"): $((total - failed - xfailed))/$((total - xfailed)) passed"
	[ "$xfailed" -gt 0 ] && msg="$msg, $xfailed known deviation(s)"
	echo "$msg"
	[ "$failed" = 0 ]
}

#!/bin/sh
# Shared harness for the initrd boot script tests.
#
# The initrd cannot be run directly on a build host, so these tests lift the
# relevant region out of initrd-src/linuxrc (or a function out of finit), stub
# the few things the initrd provides -- the param/value cheatcode readers and a
# /union that looks like a DebianDog rootfs -- and assert on what the code
# writes.  Nothing here needs root and nothing needs a built ISO.

TESTDIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$TESTDIR/../.." && pwd)
LINUXRC="$REPO/initrd-src/linuxrc"
FINIT="$REPO/initrd-src/finit"
WORK=${WORK:-/tmp/linuxrc-tests/$(basename "$0" .sh)}
RESULTS="$WORK/.results"

rm -rf "$WORK"; mkdir -p "$WORK"; : > "$RESULTS"

# ---------------------------------------------------------------- extraction

# extract_region START_RE END_RE -- print the lines of linuxrc between the
# first line matching START_RE and the first following line matching END_RE,
# excluding the end line itself.
extract_region() {
	awk -v s="$1" -v e="$2" '
		$0 ~ s { on = 1 }
		on && $0 ~ e { exit }
		on { print }
	' "$LINUXRC"
}

# The block of cheatcodes ported from Porteus/PorteuX.
extract_cheat_block() {
	extract_region '^CHEATRC=/tmp/cheatrc' '^cp -af /dev/console' | grep -v '^####'
}

# extract_func FILE NAME -- print a shell function definition by name.
extract_func() {
	awk -v n="$2" '
		$0 ~ "^" n "\\(\\) *\\{" { on = 1 }
		on { print }
		on && /^\}/ { exit }
	' "$1"
}

# --------------------------------------------------------------- fake rootfs

# Build a /union that mirrors the parts of a DebianDog image the boot scripts
# touch.  Values match a real build (see 01-filesystem.squashfs).
make_fakeroot() {
	rm -rf "$WORK/union"
	mkdir -p "$WORK/union/etc/default" "$WORK/union/etc/init.d" \
		"$WORK/union/etc/rc.d" "$WORK/union/etc/xdg/autostart" \
		"$WORK/union/root/.config/openbox" \
		"$WORK/union/home/puppy/.config/openbox" \
		"$WORK/union/usr/share/zoneinfo/Europe" "$WORK/tmp"
	printf 'XKBMODEL="pc105"\nXKBLAYOUT="us"\nXKBVARIANT=""\nXKBOPTIONS=""\n' \
		> "$WORK/union/etc/default/keyboard"
	printf '1:2345:respawn:/bin/login -f root tty6 </dev/tty1 >/dev/tty1 2>&1\n2:23:respawn:/sbin/getty 38400 tty2\n' \
		> "$WORK/union/etc/inittab"
	printf '#!/bin/sh -e\n/usr/local/bin/cowsave\nexit 0\n' > "$WORK/union/etc/rc.local"
	chmod +x "$WORK/union/etc/rc.local"
	for s in hwclock.sh bluetooth networking; do
		printf '#!/bin/sh\n' > "$WORK/union/etc/init.d/$s"
		chmod +x "$WORK/union/etc/init.d/$s"
	done
	printf '#!/bin/sh\n' > "$WORK/union/etc/rc.d/rc.network"
	chmod +x "$WORK/union/etc/rc.d/rc.network"
	: > "$WORK/union/usr/share/zoneinfo/Europe/Amsterdam"
	: > "$WORK/union/root/.config/openbox/autostart"
	: > "$WORK/union/home/puppy/.config/openbox/autostart"
	ln -sf /usr/share/zoneinfo/Etc/UTC "$WORK/union/etc/localtime"
	# /etc/profile starts X on tty1, exactly as the built image does
	printf 'export PATH\n\nif [ -z "${DISPLAY}" ] && [ $(tty) = /dev/tty1 ]\nthen\nsleep 3\nstartx\nfi\n' \
		> "$WORK/union/etc/profile"
}

# ------------------------------------------------------------------- running

# run_cheats "<kernel cmdline>" -- run the cheatcode block against the fake root.
run_cheats() {
	printf ' %s\n' "$1" > "$WORK/cmdline"
	{
		echo 'i=""'
		echo "param() { egrep -qo \" \$1( |\\\$)\" $WORK/cmdline; }"
		echo "value() { egrep -o \" \$1=[^ ]+\" $WORK/cmdline | cut -d= -f2; }"
		extract_cheat_block \
			| sed -e "s#/union#$WORK/union#g" \
			      -e "s#/tmp/cheatrc#$WORK/tmp/cheatrc#g" \
			      -e "s#/tmp/rc.local.new#$WORK/tmp/rc.local.new#g"
	} > "$WORK/block.sh"
	sh "$WORK/block.sh" > "$WORK/output" 2>&1
}

# ---------------------------------------------------------------- assertions

_pass() { echo "  PASS  $1"; echo p >> "$RESULTS"; }
_fail() { echo "  FAIL  $1"; shift; [ $# -gt 0 ] && echo "        $*"; echo f >> "$RESULTS"; }

assert_grep() {        # DESC FILE PATTERN
	if grep -q -- "$3" "$2" 2>/dev/null; then _pass "$1"
	else _fail "$1" "expected /$3/ in ${2#$WORK/}"; fi
}
assert_not_grep() {    # DESC FILE PATTERN
	if grep -q -- "$3" "$2" 2>/dev/null; then _fail "$1" "did not expect /$3/ in ${2#$WORK/}"
	else _pass "$1"; fi
}
assert_file() {        # DESC FILE
	[ -f "$2" ] && _pass "$1" || _fail "$1" "missing ${2#$WORK/}"
}
assert_no_file() {     # DESC FILE
	[ -e "$2" ] && _fail "$1" "unexpected ${2#$WORK/}" || _pass "$1"
}
assert_symlink() {     # DESC LINK [TARGET_SUBSTRING]
	if [ -L "$2" ]; then
		if [ $# -lt 3 ] || readlink "$2" | grep -q -- "$3"; then _pass "$1"
		else _fail "$1" "symlink points at $(readlink "$2")"; fi
	else _fail "$1" "${2#$WORK/} is not a symlink"; fi
}
assert_executable()     { [ -x "$2" ] && _pass "$1" || _fail "$1" "${2#$WORK/} is not executable"; }
assert_not_executable() { [ -x "$2" ] && _fail "$1" "${2#$WORK/} is still executable" || _pass "$1"; }
assert_equal() {       # DESC EXPECTED ACTUAL
	[ "$2" = "$3" ] && _pass "$1" || _fail "$1" "expected '$2', got '$3'"
}
assert_same_file() {   # DESC FILE_A FILE_B
	cmp -s "$2" "$3" && _pass "$1" || _fail "$1" "${3#$WORK/} was modified"
}

# Known gaps.  xfail records a behaviour we have decided not to support yet:
# it does not fail the suite, but if the condition starts passing the suite
# does fail, so the marker cannot rot after the gap is closed.
# Usage: xfail DESC TEST_CMD...   e.g.  xfail "symlinks" test -L "$f"
xfail() {
	desc=$1; shift
	if "$@" 2>/dev/null; then
		echo "  XPASS $desc"; echo "        now works -- turn this xfail into an assertion"
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
	[ "$xfailed" -gt 0 ] && msg="$msg, $xfailed known gap(s)"
	echo "$msg"
	[ "$failed" = 0 ]
}

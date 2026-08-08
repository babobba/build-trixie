#!/bin/sh
# fsck / fscknolog : the filesystem check and whether its log reaches the console
. "$(dirname "$0")/lib.sh"

# The check itself calls blkid/e2fsck/reiserfsck, none of which may run here,
# so they are shadowed.  `draw` is the console separator the quiet path must
# not print.
run_fsck_block() {   # $1 = cmdline
	printf ' %s\n' "$1" > "$WORK/cmdline"
	{
		echo 'i=""'
		echo "param() { egrep -qo \" \$1( |\\\$)\" $WORK/cmdline; }"
		echo 'draw() { echo "DRAW"; }'
		echo 'blkid() { echo "/dev/sda1: TYPE=\"ext4\""; }'
		echo 'e2fsck() { echo "e2fsck: checked $*"; }'
		echo 'reiserfsck() { :; }'
		echo 'wait() { :; }'
		extract_func "$FINIT" run_fsck
		extract_region '^# Perform filesystem check:' '^# Create /etc/fstab' \
			| sed "s#/tmp/fsck.log#$WORK/fsck.log#g"
	} > "$WORK/fsck.sh"
	rm -f "$WORK/fsck.log"
	sh "$WORK/fsck.sh" > "$WORK/output" 2>&1
}

echo "-- no fsck cheatcode: nothing runs"
make_fakeroot; run_fsck_block "quiet"
assert_not_grep "the check does not run" "$WORK/output" 'e2fsck'
assert_no_file  "no log is written"      "$WORK/fsck.log"

echo "-- fsck: output goes to the console"
make_fakeroot; run_fsck_block "quiet fsck"
assert_grep "the check runs"                  "$WORK/output" 'e2fsck: checked'
assert_grep "the device is passed to e2fsck"  "$WORK/output" '/dev/sda1'
assert_grep "separators are drawn"            "$WORK/output" 'DRAW'
assert_no_file "no log file is needed"        "$WORK/fsck.log"

echo "-- fscknolog: the check still runs, but quietly"
make_fakeroot; run_fsck_block "quiet fsck fscknolog"
assert_not_grep "check output is off the console" "$WORK/output" 'e2fsck: checked'
assert_not_grep "no separators are drawn"         "$WORK/output" 'DRAW'
assert_grep "the user is still told it ran"       "$WORK/output" 'filesystem check done'
assert_file "the log is kept"                     "$WORK/fsck.log"
assert_grep "the log holds the check output"      "$WORK/fsck.log" 'e2fsck: checked'
assert_grep "the log names the device checked"    "$WORK/fsck.log" '/dev/sda1'

echo "-- fscknolog without fsck does nothing"
make_fakeroot; run_fsck_block "quiet fscknolog"
assert_not_grep "the check does not run" "$WORK/output" 'e2fsck'
assert_no_file  "no log is written"      "$WORK/fsck.log"

finish

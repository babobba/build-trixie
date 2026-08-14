#!/bin/sh
# Magic folders: bind individual directories from storage over paths in the
# live system, and nomagic to skip them.
. "$(dirname "$0")/lib.sh"

run_magic() {   # $1 = cmdline
	printf ' %s\n' "$1" > "$WORK/cmdline"
	{
		echo 'i=""'; echo 'm="->"'
		echo "param() { egrep -qo \" \$1( |\\\$)\" $WORK/cmdline; }"
		echo 'mount() { echo "MOUNT $*" >> '"$WORK"'/mounts; }'
		extract_region '^# Magic folders \(Porteus\)' '^####' \
			| sed -e "s#/union#$WORK/union#g"
	} > "$WORK/mf.sh"
	: > "$WORK/mounts"
	sh "$WORK/mf.sh" > "$WORK/output" 2>&1
}

setup() {   # writes a config file, $1 = contents
	make_fakeroot
	mkdir -p "$WORK/union/etc" "$WORK/media/Downloads"
	: > "$WORK/media/mail.dat"
	printf '%s\n' "$1" > "$WORK/union/etc/magic_folders"
}

echo "-- a directory pair is bind-mounted"
setup "$WORK/media/Downloads /home/puppy/Downloads"
run_magic "quiet from=/"
assert_grep "the pair is bound"        "$WORK/mounts" "MOUNT -o bind $WORK/media/Downloads $WORK/union/home/puppy/Downloads"
assert_grep "the target is reported"   "$WORK/output" '/home/puppy/Downloads'

echo "-- a file source is loop-mounted, for FAT and NTFS media"
setup "$WORK/media/mail.dat /home/puppy/.thunderbird"
run_magic "quiet from=/"
assert_grep "the image is loop-mounted" "$WORK/mounts" "MOUNT -o loop $WORK/media/mail.dat"
assert_grep "it is flagged as an image" "$WORK/output" '(image)'

echo "-- nomagic skips everything"
setup "$WORK/media/Downloads /home/puppy/Downloads"
run_magic "quiet from=/ nomagic"
assert_equal "nothing is mounted" "" "$(cat "$WORK/mounts")"
assert_grep "the user is told"     "$WORK/output" 'nomagic - skipping magic folders'

echo "-- comments and blank lines are ignored"
setup "# a comment

$WORK/media/Downloads /home/puppy/Downloads"
run_magic "quiet from=/"
assert_equal "only the real pair is bound" "1" "$(grep -c MOUNT "$WORK/mounts")"

echo "-- a pair that would break the boot is refused"
for bad in / /proc /sys /dev /mnt; do
	setup "$WORK/media/Downloads $bad"
	run_magic "quiet from=/"
	assert_equal "$bad is refused" "" "$(cat "$WORK/mounts")"
done
assert_grep "the refusal is explained" "$WORK/output" 'would break the boot'

echo "-- a target escaping the live system is refused"
setup "$WORK/media/Downloads /home/../../etc"
run_magic "quiet from=/"
assert_equal "nothing is mounted" "" "$(cat "$WORK/mounts")"
assert_grep "'..' is rejected" "$WORK/output" "may not contain"

setup "$WORK/media/Downloads home/puppy/Downloads"
run_magic "quiet from=/"
assert_grep "a relative target is rejected" "$WORK/output" 'must be an absolute path'

echo "-- a missing source is reported, not silently skipped"
setup "$WORK/media/nothing-here /home/puppy/Downloads"
run_magic "quiet from=/"
assert_equal "nothing is mounted" "" "$(cat "$WORK/mounts")"
assert_grep "the missing source is named" "$WORK/output" 'source .* not found'

echo "-- a line with no target is reported"
setup "$WORK/media/Downloads"
run_magic "quiet from=/"
assert_grep "the incomplete line is named" "$WORK/output" 'no target given'

echo "-- no config file at all is not an error"
make_fakeroot; mkdir -p "$WORK/union/etc"; rm -f "$WORK/union/etc/magic_folders"
run_magic "quiet from=/"
assert_equal "nothing is mounted" "" "$(cat "$WORK/mounts")"
assert_not_grep "and nothing is said" "$WORK/output" 'binding magic folders'

finish

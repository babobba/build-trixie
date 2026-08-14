#!/bin/sh
# Run every image test against the built root filesystem.
#
#     ./tests/image/run.sh                 # uses trixie/isodata
#     ./tests/image/run.sh /path/to/rootfs # an already-unpacked tree
#
# Needs root when reading the squashfs, because it has to be mounted. Tests skip
# rather than fail when there is no build to look at, so this is safe to run on
# a fresh clone.
DIR=$(cd "$(dirname "$0")" && pwd)
rc=0; ran=0; skipped=0
for t in "$DIR"/test_*.sh; do
	echo "== $(basename "$t")"
	out=$(sh "$t" "$@" 2>&1); trc=$?
	echo "$out"
	# A skipped test is not a passed test. Reporting "All image tests passed"
	# when every one of them skipped is worse than reporting a failure: it
	# says the image was checked when nothing was read at all. That happened -
	# the loop devices were missing, so every test skipped on "could not
	# mount", and this script called it a pass.
	case "$out" in
		SKIP:*) skipped=$((skipped+1)) ;;
		*)      ran=$((ran+1)); [ "$trc" = 0 ] || rc=1 ;;
	esac
done
echo
if [ "$ran" = 0 ]; then
	echo "No image test actually ran ($skipped skipped) - nothing was checked."
	exit 2
fi
[ "$skipped" -gt 0 ] && echo "note: $skipped test file(s) skipped"
[ "$rc" = 0 ] && echo "All $ran image test file(s) passed." || echo "Image tests FAILED."
exit $rc

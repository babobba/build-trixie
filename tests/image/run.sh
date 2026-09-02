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
rc=0
for t in "$DIR"/test_*.sh; do
	echo "== $(basename "$t")"
	sh "$t" "$@" || rc=1
done
echo
[ "$rc" = 0 ] && echo "All image tests passed." || echo "Image tests FAILED."
exit $rc

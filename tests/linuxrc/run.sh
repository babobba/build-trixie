#!/bin/sh
# Run every linuxrc test case.  No root, no build required.
cd "$(dirname "$0")" || exit 1
rc=0; files=0; failed=0
for t in test_*.sh; do
	[ -f "$t" ] || continue
	files=$((files + 1))
	echo "== $t"
	if sh "$t"; then :; else rc=1; failed=$((failed + 1)); fi
done
echo
if [ "$rc" = 0 ]; then
	echo "All $files test file(s) passed."
else
	echo "$failed of $files test file(s) FAILED."
fi
exit $rc

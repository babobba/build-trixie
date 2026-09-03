#!/bin/sh
# Every boot test this branch has, in sequence, against trixie/isodata.
#
#     ./tests/linuxrc/boot-test-all.sh
#
# Each test rebuilds the initrd from initrd-src before booting, so this checks
# the working tree's scripts rather than whatever the last full build packed.
# A test that is not on this branch is skipped, so the same runner serves the
# sysvinit and systemd branches. Roughly three minutes per boot under TCG.
cd "$(dirname "$0")/../.." || exit 1
T=tests/linuxrc
pass=0; fail=0; skip=0

run() {   # NAME SCRIPT [VAR=VALUE ...]
	name=$1; script=$2; shift 2
	[ -x "$script" ] || { echo "##### $name: not on this branch, skipped"; skip=$((skip+1)); return; }
	echo "##### $name"
	if env "$@" "$script"; then pass=$((pass+1)); echo "##### $name PASSED"
	else fail=$((fail+1)); echo "##### $name FAILED"; fi
}

run all-cheatcodes $T/boot-test.sh
run readonly       $T/boot-test-readonly.sh
run forensic       $T/boot-test-readonly.sh  NAME=forensic CODES=forensic
run magic          $T/boot-test-nomagic.sh
run nomagic        $T/boot-test-nomagic.sh   NAME=nomagic  CODES=nomagic
run pxe            $T/boot-test-pxe.sh
run image          $T/boot-test-image.sh
run modules        $T/boot-test-modules.sh

echo
echo "boot tests: $pass passed, $fail failed, $skip not on this branch"
[ "$pass" -gt 0 ] || { echo "nothing ran - is there a built image?"; exit 2; }
[ "$fail" = 0 ]

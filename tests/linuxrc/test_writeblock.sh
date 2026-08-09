#!/bin/sh
# writeblock : set the kernel read-only flag on every disk and partition.
#
# blockdev is stubbed and the sysfs tree is faked, so the test asserts on which
# devices would have been flagged.
. "$(dirname "$0")/lib.sh"

fake_sys() {
	rm -rf "$WORK/sys" "$WORK/dev"; mkdir -p "$WORK/dev"
	for d in sda sdb nvme0n1 loop0 ram0 zram0 dm-0; do mkdir -p "$WORK/sys/block/$d"; done
	mkdir -p "$WORK/sys/block/sda/sda1" "$WORK/sys/block/sda/sda2" \
	         "$WORK/sys/block/nvme0n1/nvme0n1p1"
	# a partition is a subdirectory carrying a 'partition' file
	for p in sda/sda1 sda/sda2 nvme0n1/nvme0n1p1; do : > "$WORK/sys/block/$p/partition"; done
	# sysfs also holds non-partition subdirs; they must not be flagged
	mkdir -p "$WORK/sys/block/sda/queue" "$WORK/sys/block/sda/holders"
	for n in sda sda1 sda2 sdb nvme0n1 nvme0n1p1 loop0 ram0 zram0 dm-0; do
		: > "$WORK/dev/$n"     # stand-in for a block node
	done
}

run_wb() {   # $1 = cmdline
	printf ' %s\n' "$1" > "$WORK/cmdline"
	mkdir -p "$WORK/bin"
	if [ "${NO_BLOCKDEV:-}" = 1 ]; then
		rm -f "$WORK/bin/blockdev"
	else
		printf '#!/bin/sh\necho "$@" >> %s/flagged\nexit 0\n' "$WORK" > "$WORK/bin/blockdev"
		chmod +x "$WORK/bin/blockdev"
	fi
	{
		echo 'i=""'
		echo "PATH=$WORK/bin:\$PATH"
		echo "param() { egrep -qo \" \$1( |\\\$)\" $WORK/cmdline; }"
		echo 'sleep() { :; }'
		# -b is false for our stand-ins, so treat any existing file as a device
		echo 'test_b() { [ -e "$1" ]; }'
		extract_region '^# writeblock : set the kernel read-only flag' '^# Perform filesystem check:' \
			| sed -e "s#/sys/block#$WORK/sys/block#g" \
			      -e "s#\[ -b /dev/\\\$PN \]#test_b $WORK/dev/\$PN#" \
			      -e "s#blockdev --setro /dev/#blockdev --setro $WORK/dev/#" \
			      -e "s#\[ -x /bin/blockdev \] || \[ -x /sbin/blockdev \]#[ -x $WORK/bin/blockdev ]#"
	} > "$WORK/wb.sh"
	: > "$WORK/flagged"
	sh "$WORK/wb.sh" > "$WORK/output" 2>&1
}

echo "-- without the cheatcode nothing is touched"
fake_sys; run_wb "quiet from=/"
assert_equal "no device is flagged" "" "$(cat "$WORK/flagged")"

echo "-- writeblock flags disks and their partitions"
fake_sys; run_wb "quiet from=/ writeblock"
for d in sda sda1 sda2 sdb nvme0n1 nvme0n1p1; do
	assert_grep "$d is set read-only" "$WORK/flagged" "--setro .*/dev/$d\$"
done

echo "-- virtual devices are left alone"
# loop is needed to mount the squashfs, any ISO and any changes file; flagging
# ram/zram/dm would break tmpfs-backed changes and encrypted mappings.
for d in loop0 ram0 zram0 dm-0; do
	assert_not_grep "$d is not flagged" "$WORK/flagged" "/dev/$d\$"
done
assert_not_grep "sysfs queue dir is not treated as a device" "$WORK/flagged" '/dev/queue'
assert_equal "each device is flagged once" "6" "$(wc -l < "$WORK/flagged" | tr -d ' ')"

echo "-- the user is told what happened, and what it is not"
assert_grep "devices are listed"        "$WORK/output" 'write-blocking devices:'
assert_grep "the limitation is stated"  "$WORK/output" 'not a hardware write blocker'

echo "-- a missing blockdev must warn loudly rather than pretend"
fake_sys; NO_BLOCKDEV=1 run_wb "quiet from=/ writeblock"
assert_grep "the failure is explicit" "$WORK/output" 'NOT protected'
assert_equal "nothing was flagged" "" "$(cat "$WORK/flagged")"

finish

#!/bin/sh
# readonly : discovered filesystems must be mounted without writing to them.
#
# Finding the boot medium means mounting every partition, and the default
# options are read-write, so an ordinary boot writes to each one before noauto
# unmounts anything.  These tests drive fstab() with blkid and mount stubbed
# and assert on the options that would have been used.
. "$(dirname "$0")/lib.sh"

run_fstab() {   # $1 = cmdline
	printf ' %s\n' "$1" > "$WORK/cmdline"
	mkdir -p "$WORK/etc" "$WORK/tmp"
	# ntfs-3g cannot be a shell function (dash rejects the hyphen), so it is a
	# stub on PATH instead.
	mkdir -p "$WORK/bin"
	printf '#!/bin/sh\necho "NTFS3G $*" >> %s/mounts\n' "$WORK" > "$WORK/bin/ntfs-3g"
	chmod +x "$WORK/bin/ntfs-3g"
	{
		echo 'i=""'
		echo "PATH=$WORK/bin:\$PATH"
		echo "param() { egrep -qo \" \$1( |\\\$)\" $WORK/cmdline; }"
		echo "value() { egrep -o \" \$1=[^ ]+\" $WORK/cmdline | cut -d= -f2; }"
		# blkid must honour its argument: fstab() calls it once per /dev/sr*
		# and once bare, so a stub that ignores $1 duplicates every device and
		# $fs comes out as "ext4 ext4".
		echo 'blkid() {
  all="/dev/sda1: TYPE=\"ext4\"
/dev/sda2: TYPE=\"ntfs\"
/dev/sdb1: TYPE=\"vfat\""
  if [ $# -eq 0 ]; then echo "$all"; else echo "$all" | grep "^$1:" || return 1; fi
}'
		echo 'mount() { echo "MOUNT $*" >> '"$WORK"'/mounts; }'
		echo 'modprobe() { :; }'
		extract_region '^MOPT=' '^CHANGES='
		# fstab() ends with "fi }", not a brace at column 0, so bound it by the
		# next function rather than by extract_func.
		awk '/^fstab\(\) \{/,/^mount_device\(\)/' "$FINIT" | grep -v '^mount_device' \
			| sed -e "s#/etc/fstab#$WORK/etc/fstab#g" \
			      -e "s#/tmp/devices#$WORK/tmp/devices#g" -e "s#/mnt/#$WORK/mnt/#g"
		echo 'fstab'
	} > "$WORK/fs.sh"
	rm -rf "$WORK/mnt" "$WORK/etc/fstab" "$WORK/mounts"; mkdir -p "$WORK/mnt"; : > "$WORK/mounts"
	sh "$WORK/fs.sh" > "$WORK/output" 2>&1
}

echo "-- default: mounts are read-write, as before"
run_fstab "quiet from=/"
assert_grep "ext4 line has the rw defaults" "$WORK/etc/fstab" 'ext4 noatime,nodiratime,suid,dev,exec,async'
assert_not_grep "nothing is mounted ro"     "$WORK/etc/fstab" '[ ,]ro[, ]'
assert_not_grep "no noload is added"        "$WORK/etc/fstab" 'noload'

echo "-- readonly: every filesystem type is mounted ro"
run_fstab "quiet from=/ readonly"
assert_grep "ext4 is ro"        "$WORK/etc/fstab" '/dev/sda1 .* ext4 ro,'
assert_grep "vfat is ro"        "$WORK/etc/fstab" '/dev/sdb1 .* vfat ro,'
assert_grep "ntfs-3g is told ro" "$WORK/mounts"   'NTFS3G /dev/sda2 .* -o ro,'
assert_not_grep "no rw options survive" "$WORK/etc/fstab" 'exec,async'

echo "-- readonly: a dirty ext journal is not replayed"
# A read-only mount still replays the journal, which writes to the filesystem
# readonly is supposed to leave untouched.  noload is what actually prevents it.
assert_grep "ext4 gets noload"  "$WORK/etc/fstab" 'ext4 ro,noatime,nodiratime,noload'
assert_not_grep "vfat has no noload" "$WORK/etc/fstab" 'vfat.*noload'

echo "-- mopt= still wins, so the old workaround keeps working"
run_fstab "quiet from=/ mopt=ro,sync"
assert_grep "mopt= is used verbatim" "$WORK/etc/fstab" 'ext4 ro,sync'

finish

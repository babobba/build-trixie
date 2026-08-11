#!/bin/sh
# Boot test for readonly and forensic.
#
# These are the two cheatcodes where a mistake means an unbootable system:
# forensic marks every device read-only including the boot medium, so if the
# reasoning about read-only mounts is wrong, the machine never comes up. That
# is exactly what a boot test is for, and no unit test can show it.
NAME=${NAME:-readonly}
SCRATCH=1
CODES="${CODES:-readonly}"
# Find the scratch disk by label rather than guessing a device name: the
# filesystem is on the whole disk, so it appears as /dev/sda, not /dev/sda1,
# and a hardcoded path made the write probe pass by writing nowhere.
REPORT='
SDEV=$(blkid -L SCRATCH 2>/dev/null)
echo "SDEV=${SDEV:-NONE}"
MLINE=$(grep "^$SDEV " /proc/mounts 2>/dev/null | head -1)
echo "MOUNTLINE=${MLINE:-NOTMOUNTED}"
MP=$(echo "$MLINE" | cut -d" " -f2)
if [ -n "$MP" ]; then
  if touch "$MP/.probe" 2>/dev/null; then echo "WRITETEST=WRITABLE"; rm -f "$MP/.probe"
  else echo "WRITETEST=REFUSED"; fi
else
  echo "WRITETEST=NOMOUNT"
fi
echo "SCRATCH_RO=$(blockdev --getro $SDEV 2>/dev/null || echo unknown)"
# The whole disk as well as the partition: forensic has to walk from
# /sys/block/<disk> into its partition subdirectories, and getting only the
# disk right is the failure mode that a whole-disk scratch image hid.
WDEV=$(echo "$SDEV" | sed -e "s/p\?[0-9]*$//")
echo "WDEV=${WDEV:-NONE}"
echo "DISK_RO=$(blockdev --getro $WDEV 2>/dev/null || echo unknown)"
'
. "$(dirname "$0")/boot-lib.sh"

bt_build
bt_boot

echo "== results"
bt_check "the system booted at all"        '===CLI-END==='
# The scratch disk must actually have been found and mounted, or every check
# below passes by testing nothing.
bt_check     "the scratch disk was found"            '^SDEV=/dev/'
bt_check_not "and it was mounted"                    '^MOUNTLINE=NOTMOUNTED$'
bt_check_not "so the write probe means something"    '^WRITETEST=NOMOUNT$'
# The filesystem is on partition 1, so a device name ending in a digit is what
# proves the partitioned layout survived into the guest.  Without it the
# partition-enumeration checks below are back to testing nothing.
bt_check     "and it is a partition, not the whole disk" '^SDEV=/dev/[a-z]*[0-9]$'
case "$CODES" in
  *forensic*)
	bt_check "the partition is block-level read-only"    '^SCRATCH_RO=1$'
	bt_check "the whole disk is too"                     '^DISK_RO=1$'
	bt_check "forensic implied read-only mounts"         '^MOUNTLINE=.* ro[, ]'
	bt_check "writing to a found filesystem is refused"  '^WRITETEST=REFUSED$' ;;
  *)
	bt_check "the scratch disk is mounted read-only"     '^MOUNTLINE=.* ro[, ]'
	bt_check "writing to it is refused"                  '^WRITETEST=REFUSED$'
	bt_check "the block flag is NOT set by readonly"     '^SCRATCH_RO=0$' ;;
esac
bt_finish

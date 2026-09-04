#!/bin/sh
# Does the image boot through UEFI firmware?
#
# The BIOS path is what every other boot test exercises. This one boots the
# same ISO through OVMF: the EFI El Torito image (efiboot.img, shim and grub)
# has to be found by the firmware, grub has to find /boot/grub/grub.cfg on the
# medium and start the kernel, and the initrd then has to find the medium as
# it does under BIOS. The proof that it was EFI and not a fallback to the
# BIOS path is /sys/firmware/efi, which exists only on an EFI boot.
#
# Needs an isodata built with ISOUEFI=TRUE; skips otherwise.
NAME=${NAME:-uefi}
FIRMWARE=uefi
REPORT='
echo "EFI=$(test -d /sys/firmware/efi && echo YES || echo NO)"
echo "EFIBITS=$(cat /sys/firmware/efi/fw_platform_size 2>/dev/null)"
echo "EFIVARS=$(ls /sys/firmware/efi/efivars 2>/dev/null | wc -l)"
echo "EFIVARFS_MOUNT=$(findmnt -n -o FSTYPE /sys/firmware/efi/efivars 2>/dev/null || echo NONE)"
echo "EFIVARFS_MODULE=$(modprobe efivarfs 2>&1 && echo LOADED || echo FAILED)"
echo "EFIVARFS_MANUAL=$(mount -t efivarfs efivarfs /sys/firmware/efi/efivars 2>&1 && ls /sys/firmware/efi/efivars | wc -l || echo MOUNTFAIL)"
echo "EFIVARS_JOURNAL=$(journalctl -b --no-pager 2>/dev/null | grep -i efivar | head -3 | tr "\n" ";")"
echo "INIT=$(ps -p 1 -o comm=)"
echo "OSID=$(. /etc/os-release; echo $ID-$VERSION_ID)"
echo "SQFS=$(grep -c squashfs /proc/mounts)"
echo "BOOTDEV=$(cat /run/initramfs/etc/homedrv 2>/dev/null || cat /mnt/live/etc/homedrv 2>/dev/null)"
'
. "$(dirname "$0")/boot-lib.sh"

[ -f "$ISODATA/efiboot.img" ] || bt_skip "$ISODATA has no efiboot.img - build with ISOUEFI=TRUE for this test"

bt_build
bt_boot

echo "== results"
bt_check "the system booted at all" '===CLI-END==='
sed -n '/===CLI-MARKER===/,/===CLI-END===/p' "$SER.clean" | sed 's/^/   | /'
echo "-- it was an EFI boot, not a BIOS fallback"
bt_check "the kernel runs with EFI runtime services" '^EFI=YES$'
bt_check "64-bit firmware"                            '^EFIBITS=64$'
bt_check "EFI variables are visible"                  '^EFIVARS=[1-9]'
echo "-- and the live system is the same one"
bt_check "squashfs modules are mounted"               '^SQFS=[1-9]'
bt_check "the initrd found the medium"                '^BOOTDEV=/mnt/'

bt_finish

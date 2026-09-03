#!/bin/sh
# The initrd must carry drivers for the storage a virtual machine actually
# presents, and modlist must name them or linuxrc never modprobes them.
. "$(dirname "$0")/lib.sh"

MODLIST="$REPO/initrd-src/modlist"
MKINITRD="$REPO/dog-boot-trixie-20240602/usr/local/mkinitrd"

echo "-- modlist names what no device announces, and nothing that one does"
# The list is the part of module loading that cannot be driven by hardware:
# filesystems, the storage and USB classes, HID. Everything with a PCI, USB,
# virtio, vmbus or ACPI identity is loaded from its modalias in /sys, so a
# driver name here would be a regression back to probing by list.
for m in overlay squashfs loop isofs ext4 vfat exfat btrfs \
         sd_mod sr_mod usb_storage uas usbhid hid_generic; do
	assert_grep "modlist has $m" "$MODLIST" "\\b$m\\b"
done
# Each name is one modprobe process, so the list carries no dependencies
# (fat, cdrom, jbd2 come in with vfat, sr_mod, ext4), no aliases of a module
# already named (ext2 and ext3 are ext4), nothing the kernel autoloads at
# mount time (the nls_ tables), and nothing linuxrc loads itself when a
# cheatcode asks for it (dm_crypt and its ciphers).
for m in fat cdrom jbd2 ext2 ext3 dm_crypt cryptd xts; do
	assert_not_grep "modlist does not carry $m" "$MODLIST" "\\b$m\\b"
done
# The nls tables are requested by the kernel when a vfat, ntfs or joliet
# filesystem is mounted - not a dependency modprobe can see, and this
# initrd historically had no /sbin/modprobe for the kernel to call, so
# they are loaded by name as they always were. A FAT stick is the most
# common live medium there is.
for m in nls_cp437 nls_iso8859_1 nls_utf8; do
	assert_grep "modlist carries $m for FAT media" "$MODLIST" "\\b$m\\b"
done
# One dependency is listed on purpose. ext4, btrfs, xfs and f2fs need the
# crc32c algorithm, but only as a soft dependency the kernel requests by
# alias at mount time, and busybox's modprobe does not follow softdeps.
# Without it here an ext4 partition simply fails to mount in the initrd -
# the readonly, forensic and magic boot tests caught exactly that.
assert_grep "modlist carries crc32c_generic, ext4's soft dependency" "$MODLIST" '\bcrc32c_generic\b'
for m in ahci nvme ata_piix xhci_hcd e1000e virtio_blk virtio_scsi hv_vmbus vmxnet3 xen_blkfront; do
	assert_not_grep "modlist does not name $m" "$MODLIST" "\\b$m\\b"
done

echo "-- linuxrc loads hardware drivers from what /sys reports"
LINUXRC="$REPO/initrd-src/linuxrc"
assert_grep "it walks the modaliases"       "$LINUXRC" '/sys/bus/\*/devices/\*/modalias'
assert_grep "and runs a second pass"         "$LINUXRC" 'load_by_modalias 2'
assert_not_grep "the ata unload loop is gone" "$LINUXRC" 'modprobe -r \$MODULE'
# Under nohotplug nothing is probed, the list included - that is what the
# cheatcode has always meant.
assert_grep "nohotplug still skips it all"   "$LINUXRC" 'nohotplug - skipping automatic module loading'

echo "-- the virtual machine drivers still ship in the initrd, to be found by modalias"
echo "-- mkinitrd copies them into the initrd"
assert_grep "virtio device dir"  "$MKINITRD" 'drivers/virtio$'
assert_grep "virtio_blk"         "$MKINITRD" 'drivers/block/virtio_blk\.'
assert_grep "virtio_scsi"        "$MKINITRD" 'drivers/scsi/virtio_scsi\.'
assert_grep "virtio_net"         "$MKINITRD" 'drivers/net/virtio_net\.'
assert_grep "hyper-v vmbus dir"  "$MKINITRD" 'drivers/hv$'
assert_grep "hyper-v storage"    "$MKINITRD" 'drivers/scsi/hv_storvsc\.'
assert_grep "vmware pvscsi"      "$MKINITRD" 'drivers/scsi/vmw_pvscsi\.'
assert_grep "vmware vmxnet3"     "$MKINITRD" 'drivers/net/vmxnet3'
assert_grep "xen blkfront"       "$MKINITRD" 'drivers/block/xen-blkfront\.'

echo "-- mkinitrd prebuilds modprobe's index and ships a slim network set"
assert_grep "index is prebuilt"  "$MKINITRD" 'modules.dep.bb'
assert_grep "NETWORK defaults to common" "$MKINITRD" 'NETWORK=\${NETWORK:-common}'
assert_grep "common keeps e1000e"  "$MKINITRD" 'intel/e1000e'
assert_grep "common keeps realtek" "$MKINITRD" 'ethernet/\$d'
assert_grep "the initrd is zstd"   "$MKINITRD" 'zstd -q -19'

echo "-- modlist keeps its original shape: one unterminated space-separated line"
# linuxrc does `for MODULE in $(cat modlist)`, and the shipped file carries no
# newline at all, so a stray newline would be a format change rather than a fix.
assert_equal "no newlines" "0" "$(wc -l < "$MODLIST" | tr -d ' ')"
assert_not_grep "no tabs" "$MODLIST" '	'
assert_equal "every entry is a bare module name" "" \
	"$(tr ' ' '\n' < "$MODLIST" | grep -vE '^[A-Za-z0-9_-]*$' | tr '\n' ' ')"

echo "-- build-trixie ships modlist from initrd-src"
assert_grep "modlist is overlaid onto the skeleton" \
	"$REPO/build-trixie" 'initrd-src/modlist'

finish

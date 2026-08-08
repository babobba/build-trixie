#!/bin/sh
# The initrd must carry drivers for the storage a virtual machine actually
# presents, and modlist must name them or linuxrc never modprobes them.
. "$(dirname "$0")/lib.sh"

MODLIST="$REPO/initrd-src/modlist"
MKINITRD="$REPO/dog-boot-trixie-20240602/usr/local/mkinitrd"

echo "-- modlist names the virtual machine drivers"
for m in virtio_blk virtio_scsi virtio_net virtio_mmio \
         hv_vmbus hv_storvsc vmw_pvscsi vmxnet3 xen_blkfront; do
	assert_grep "modlist has $m" "$MODLIST" "\\b$m\\b"
done

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

echo "-- the pre-existing entries are still there"
for m in ahci nvme usb_storage squashfs overlay loop sd_mod sr_mod; do
	assert_grep "modlist still has $m" "$MODLIST" "\\b$m\\b"
done

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

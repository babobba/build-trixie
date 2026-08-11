#!/bin/sh
# Shared machinery for the boot tests.
#
# The important part is repack_initrd: a boot test must exercise the scripts in
# initrd-src, not whichever ones happened to be in the last full build. Without
# that, a branch's own changes are never actually booted, and the test passes
# by testing the previous branch's code.
#
# console=ttyS0 is on the boot line so the initrd's own messages reach the
# serial log too.  Without it a cheatcode that reports its own failure on the
# console is invisible to the test, and a silent no-op is indistinguishable
# from success.
#
# Callers set these before sourcing:
#   CODES    extra cheatcodes appended to the boot line
#   REPORT   extra shell added to the in-guest report (writes to /dev/ttyS0)
#   SCRATCH  1 to attach a scratch ext4 disk as a second drive
# and then call: bt_build; bt_boot; bt_check "desc" "pattern"; bt_finish

CLI_TIMEOUT=${CLI_TIMEOUT:-180}
GUI_TIMEOUT=${GUI_TIMEOUT:-240}

set -u
BT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$BT_DIR/../.." && pwd)
ISODATA=${ISODATA:-$REPO/trixie/isodata}
NAME=${NAME:-boot}
WORK=${WORK:-/tmp/linuxrc-$NAME}
MON=/tmp/lbt-$NAME.sock          # QEMU rejects socket paths over 107 bytes
CODES=${CODES:-}
REPORT=${REPORT:-}
SCRATCH=${SCRATCH:-0}
bt_pass=0; bt_bad=0

bt_fail() { echo "FAIL: $*"; exit 1; }
bt_skip() { echo "SKIP: $*"; exit 0; }

command -v qemu-system-x86_64 >/dev/null || bt_skip "qemu-system-x86_64 not installed"
command -v xorriso >/dev/null || bt_skip "xorriso not installed"
command -v cpio >/dev/null || bt_skip "cpio not installed"

# Rebuild initrd1.xz around the scripts in initrd-src, so the test boots the
# code in the working tree.  blockdev is injected the way mkinitrd does it,
# taken from the built rootfs so the libc matches the guest rather than the
# build host.
repack_initrd() {
	IRD="$WORK/ird"; rm -rf "$IRD"; mkdir -p "$IRD"
	( cd "$IRD" && xz -dc "$WORK/iso/live/initrd1.xz" | cpio -idm --quiet 2>/dev/null ) \
		|| bt_fail "could not unpack initrd1.xz"
	for f in linuxrc finit modlist; do
		[ -f "$REPO/initrd-src/$f" ] && cp -f "$REPO/initrd-src/$f" "$IRD/$f"
	done
	chmod +x "$IRD/linuxrc"

	if ! [ -x "$IRD/bin/blockdev" ] && ! [ -x "$IRD/sbin/blockdev" ] \
	   && grep -q "blockdev" "$REPO/dog-boot-trixie-20240602/usr/local/mkinitrd" 2>/dev/null; then
		SQ="$WORK/sq"; mkdir -p "$SQ"
		if mount -o loop,ro "$ISODATA/live/01-filesystem.squashfs" "$SQ" 2>/dev/null; then
			if [ -f "$SQ/sbin/blockdev" ]; then
				mkdir -p "$IRD/sbin"
				cp -f "$SQ/sbin/blockdev" "$IRD/sbin/blockdev"
				# blockdev is dynamically linked; bring its libraries AND the
				# dynamic loader.  The loader appears in ldd output as a bare
				# path with no "=>", so matching only "=>" lines leaves the
				# binary unable to execute at all - which looks exactly like
				# the cheatcode silently doing nothing.  This mirrors the
				# parsing mkinitrd already uses.
				for lib in $(ldd "$SQ/sbin/blockdev" 2>/dev/null \
				             | sed -r "s/.*=>//; s/[(].*//; s/^\s+|\s+$//" \
				             | grep "^/"); do
					[ -f "$SQ$lib" ] && { mkdir -p "$IRD$(dirname "$lib")"; cp -f "$SQ$lib" "$IRD$lib"; }
				done
				echo "   injected blockdev into the initrd (as mkinitrd does)"
			fi
			umount "$SQ" 2>/dev/null
		fi
		rmdir "$SQ" 2>/dev/null
	fi

	( cd "$IRD" && find . | cpio -o -H newc --quiet 2>/dev/null | xz -f --check=crc32 ) \
		> "$WORK/iso/live/initrd1.xz" || bt_fail "could not repack initrd1.xz"
}

bt_build() {
	[ -d "$ISODATA/live" ] || bt_fail "no isodata at $ISODATA - run build-trixie first"
	echo "== building test ISO ($NAME)"
	rm -rf "$WORK"; mkdir -p "$WORK"
	cp -a "$ISODATA" "$WORK/iso" || bt_fail "could not copy isodata"
	repack_initrd
	mkdir -p "$WORK/iso/live/rootcopy/usr/local/bin"

	{
		echo '#!/bin/sh'
		echo 'exec > /dev/ttyS0 2>&1'
		echo 'echo "===CLI-MARKER==="'
		echo "$REPORT"
		echo 'echo "===CLI-END==="'
	} > "$WORK/iso/live/rootcopy/usr/local/bin/rcli"
	printf '#!/bin/sh\necho "===GUI-MARKER===" > /dev/ttyS0\n' \
		> "$WORK/iso/live/rootcopy/usr/local/bin/rgui"
	chmod +x "$WORK/iso/live/rootcopy/usr/local/bin/rcli" \
	         "$WORK/iso/live/rootcopy/usr/local/bin/rgui"

	cat >> "$WORK/iso/isolinux/live.cfg" <<EOF

label BOOT-TEST
menu default
kernel /live/vmlinuz1
append initrd=/live/initrd1.xz console=ttyS0,115200 from=/ base_only $CODES cliexec=/usr/local/bin/rcli guiexec=/usr/local/bin/rgui
EOF

	( cd "$WORK/iso" && xorriso -as mkisofs -r -J -joliet-long -l \
	    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin -partition_offset 16 \
	    -V boottest -b isolinux/isolinux.bin -c isolinux/boot.cat \
	    -no-emul-boot -boot-load-size 4 -boot-info-table \
	    -o "$WORK/boot-test.iso" . ) >"$WORK/xorriso.log" 2>&1 \
	    || bt_fail "xorriso failed, see $WORK/xorriso.log"

	if [ "$SCRATCH" = 1 ]; then
		# A disk for the guest to find, so the mount options it chooses can be
		# observed.  Left dirty-free and unremarkable on purpose.
		dd if=/dev/zero of="$WORK/scratch.img" bs=1M count=64 status=none
		mkfs.ext4 -q -F -L SCRATCH "$WORK/scratch.img" 2>/dev/null \
			|| bt_skip "mkfs.ext4 not available"
		mkdir -p "$WORK/mnt" && mount -o loop "$WORK/scratch.img" "$WORK/mnt" 2>/dev/null && {
			mkdir -p "$WORK/mnt/magicsrc"; echo "from the scratch disk" > "$WORK/mnt/magicsrc/hello"
			umount "$WORK/mnt"; }
		rmdir "$WORK/mnt" 2>/dev/null
	fi
}

bt_boot() {
	echo "== booting (cliexec budget ${CLI_TIMEOUT}s, guiexec budget ${GUI_TIMEOUT}s)"
	SER="$WORK/serial.log"; : > "$SER"; rm -f "$MON"
	DISK=""
	[ "$SCRATCH" = 1 ] && DISK="-drive file=$WORK/scratch.img,format=raw,if=ide,index=1"
	# shellcheck disable=SC2086
	qemu-system-x86_64 -accel tcg,thread=multi,tb-size=1024 -m 3072 -smp 4 \
	  -cdrom "$WORK/boot-test.iso" -boot d $DISK -display none -vga std \
	  -monitor unix:"$MON",server,nowait -serial file:"$SER" -no-reboot \
	  > "$WORK/qemu.log" 2>&1 &
	QPID=$!
	trap 'kill $QPID 2>/dev/null' EXIT INT TERM

	start=$(date +%s); cli=""; gui=""
	while :; do
		now=$(( $(date +%s) - start ))
		[ -z "$cli" ] && grep -q "CLI-END" "$SER" 2>/dev/null && { cli=$now; echo "   cliexec stage at ${cli}s"; }
		[ -z "$gui" ] && grep -q "GUI-MARKER" "$SER" 2>/dev/null && { gui=$now; echo "   guiexec stage at ${gui}s"; break; }
		kill -0 $QPID 2>/dev/null || { echo "   qemu exited early"; break; }
		[ -z "$cli" ] && [ "$now" -ge "$CLI_TIMEOUT" ] && break
		[ "$now" -ge "$GUI_TIMEOUT" ] && break
		sleep 3
	done
	kill $QPID 2>/dev/null; wait $QPID 2>/dev/null
	[ -n "$cli" ] || bt_fail "cliexec stage not reached within ${CLI_TIMEOUT}s (see $SER)"
	# The guest writes to a tty, so \n becomes \r\n; a trailing \r defeats any
	# pattern anchored with $, which looks like a failing cheatcode.
	tr -d '\r' < "$SER" > "$SER.clean"
	BT_CLI=$cli; BT_GUI=${gui:-}
}

bt_check() {   # DESC PATTERN
	if grep -q -- "$2" "$SER.clean"; then echo "   PASS  $1"; bt_pass=$((bt_pass+1))
	else echo "   FAIL  $1 (wanted /$2/)"; bt_bad=$((bt_bad+1)); fi
}
bt_check_not() {   # DESC PATTERN
	if grep -q -- "$2" "$SER.clean"; then echo "   FAIL  $1 (did not want /$2/)"; bt_bad=$((bt_bad+1))
	else echo "   PASS  $1"; bt_pass=$((bt_pass+1)); fi
}

bt_finish() {
	echo
	if [ "$bt_bad" -eq 0 ]; then
		echo "$NAME boot test passed: $bt_pass checks, cliexec ${BT_CLI}s"
	else
		echo "$NAME boot test FAILED: $bt_bad of $((bt_pass+bt_bad)) checks (serial: $SER.clean)"
		exit 1
	fi
}

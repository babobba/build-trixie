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
# base_only keeps every test to the base squashfs, so a module on the medium
# cannot mask a regression in the base; BASE_ONLY=0 is for the one test whose
# subject is the modules themselves.
BASE_ONLY=${BASE_ONLY:-1}
# FIRMWARE=uefi boots the test ISO through OVMF instead of SeaBIOS. The ISO
# must have been built from isodata-uefi (it carries efiboot.img and
# boot/grub); the test ISO is then made hybrid the way build-trixie makes
# the shipped one, and the boot line goes into grub.cfg as the default entry
# as well as into isolinux's.
# FIRMWARE=uefi-secure boots with Secure Boot enforced and Microsoft's keys
# enrolled (OVMF's .ms variables), which is what a retail PC ships with: only
# a shim signed by Microsoft starts, and it only starts a grub signed by the
# distribution key it trusts.
FIRMWARE=${FIRMWARE:-bios}
if [ "$FIRMWARE" = uefi-secure ]; then
	OVMF_CODE=${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.secboot.fd}
	OVMF_VARS=${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.ms.fd}
else
	OVMF_CODE=${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}
	OVMF_VARS=${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}
fi
bt_pass=0; bt_bad=0

bt_fail() { echo "FAIL: $*"; exit 1; }
bt_skip() { echo "SKIP: $*"; exit 0; }

command -v qemu-system-x86_64 >/dev/null || bt_skip "qemu-system-x86_64 not installed"
command -v xorriso >/dev/null || bt_skip "xorriso not installed"
command -v cpio >/dev/null || bt_skip "cpio not installed"

# The initrd may be xz (the historic format) or zstd (what mkinitrd writes
# when zstd is installed); the file is called initrd1.xz either way. Detect by
# magic, and repack with whatever it was, so a test boots the format the build
# produced.
bt_initrd_format() {   # FILE -> xz | zstd
	case "$(od -An -tx1 -N4 "$1" | tr -d ' \n')" in
		fd377a58) echo xz ;;
		28b52ffd) echo zstd ;;
		*) bt_fail "$1 is neither an xz nor a zstd initrd" ;;
	esac
}
bt_initrd_unpack() {   # FILE DIR
	case "$(bt_initrd_format "$1")" in
		xz)   ( cd "$2" && xz -dc "$1" | cpio -idm --quiet 2>/dev/null ) ;;
		zstd) ( cd "$2" && zstd -dc "$1" | cpio -idm --quiet 2>/dev/null ) ;;
	esac
}
bt_initrd_pack() {     # DIR FORMAT > stdout
	case "$2" in
		xz)   ( cd "$1" && find . | cpio -o -H newc --quiet 2>/dev/null | xz -f --check=crc32 ) ;;
		zstd) ( cd "$1" && find . | cpio -o -H newc --quiet 2>/dev/null | zstd -q -19 -T0 ) ;;
	esac
}

# The same rule as mkinitrd's modprobe -D pass, without needing kmod on the
# host: a name is kept if modules.dep lists it, or modules.alias names it
# exactly (ext2 is an alias of ext4), and modules.builtin does not.
filter_modlist() {
	KV=$(ls "$IRD/lib/modules" | head -1); D="$IRD/lib/modules/$KV"
	{ sed -n 's|^.*/\([^/]*\)\.ko:.*|\1|p' "$D/modules.dep"
	  sed -n 's/^alias \([^*? ]*\) .*/\1/p' "$D/modules.alias"; } | tr - _ | sort -u > "$WORK/mods.present"
	sed -n 's|^.*/\([^/]*\)\.ko$|\1|p' "$D/modules.builtin" | tr - _ | sort -u > "$WORK/mods.builtin"
	: > "$IRD/modlist"
	for m in $(cat "$REPO/initrd-src/modlist"); do
		n=$(echo "$m" | tr - _)
		grep -qx "$n" "$WORK/mods.present" && ! grep -qx "$n" "$WORK/mods.builtin" && printf '%s ' "$m" >> "$IRD/modlist"
	done
	echo "   modlist: $(wc -w < "$IRD/modlist") of $(wc -w < "$REPO/initrd-src/modlist") names resolve in this initrd"
}

# Rebuild initrd1.xz around the scripts in initrd-src, so the test boots the
# code in the working tree.  blockdev is injected the way mkinitrd does it,
# taken from the built rootfs so the libc matches the guest rather than the
# build host.
repack_initrd() {
	IRD="$WORK/ird"; rm -rf "$IRD"; mkdir -p "$IRD"
	IRD_FMT=$(bt_initrd_format "$WORK/iso/live/initrd1.xz")
	case "$IRD_FMT" in xz|zstd) ;; *) bt_fail "$IRD_FMT" ;; esac
	bt_initrd_unpack "$WORK/iso/live/initrd1.xz" "$IRD" || bt_fail "could not unpack initrd1.xz"
	echo "   initrd is $IRD_FMT"
	for f in linuxrc finit; do
		[ -f "$REPO/initrd-src/$f" ] && cp -f "$REPO/initrd-src/$f" "$IRD/$f"
	done
	chmod +x "$IRD/linuxrc"
	# modlist is not copied verbatim. mkinitrd keeps only the names that
	# resolve to a module in the initrd (a real file, or an alias of one, and
	# not built in), and the boot loop is sized by that list. Copying the raw
	# source list booted every test with ~100 extra modprobe calls that the
	# shipped initrd never makes, which inflated the profiler's numbers.
	[ -f "$REPO/initrd-src/modlist" ] && filter_modlist

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

	bt_initrd_pack "$IRD" "$IRD_FMT" > "$WORK/iso/live/initrd1.xz" || bt_fail "could not repack initrd1.xz"
}

# The packages a build config installs, as one list. The program tests draw
# their subjects from this so that the list follows the config rather than a
# hand-kept copy of it; a package that is named here and missing from the
# medium is then a finding, not a gap in the test.
# MODULE_PACKAGES are installed with the rest and then moved out of the base
# into a squashfs module on the medium, so they are on the list only when
# the test loads the modules (BASE_ONLY=0).
bt_config_packages() {   # CONFIG
	[ -f "$1" ] || bt_fail "no config at $1"
	( set +u; . "$1" >/dev/null 2>&1
	  echo $BASE_INSTALL $BASE_DOG_APPS_INSTALL $BASE_APPS_INSTALL $DESK_APPS_INSTALL \
	       $EXTRA_DOG_APPS_INSTALL $FIRMWARE $MODULE_PACKAGES | tr ' ' '\n' | grep . | sort -u \
	    | if [ "$BASE_ONLY" = 1 ] && [ -n "$MODULE_PACKAGES" ]; then
	          grep -vxF "$(echo $MODULE_PACKAGES | tr ' ' '\n')"; else cat; fi )
}

# Ask the QEMU monitor for a screenshot (PPM, converted to PNG when a
# converter is at hand). For a GUI failure the picture says more than the
# serial log.
bt_screendump() {   # FILE.ppm
	python3 - "$MON" "$1" <<'PY' 2>/dev/null
import socket, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(5)
s.connect(sys.argv[1]); time.sleep(0.3); s.recv(4096)
s.sendall(("screendump %s\n" % sys.argv[2]).encode()); time.sleep(1.5)
try: s.recv(4096)
except Exception: pass
PY
	if command -v pnmtopng >/dev/null 2>&1; then pnmtopng "$1" > "${1%.ppm}.png" 2>/dev/null && rm -f "$1"
	elif command -v convert >/dev/null 2>&1; then convert "$1" "${1%.ppm}.png" 2>/dev/null && rm -f "$1"; fi
}

bt_build() {
	[ -d "$ISODATA/live" ] || bt_fail "no isodata at $ISODATA - run build-trixie first"
	for f in vmlinuz1 initrd1.xz 01-filesystem.squashfs; do
		[ -s "$ISODATA/live/$f" ] || bt_fail "no $f in $ISODATA/live - the build did not finish"
	done
	echo "== building test ISO ($NAME)"
	rm -rf "$WORK"; mkdir -p "$WORK"
	cp -a "$ISODATA" "$WORK/iso" || bt_fail "could not copy isodata"
	repack_initrd
	mkdir -p "$WORK/iso/live/rootcopy/usr/local/bin"

	# The report's lines each go out through a fresh open of the serial
	# device rather than one descriptor held for the run. systemd starts a
	# getty on ttyS0 (console= puts it there) some seconds into the boot,
	# and agetty hangs the line up as it starts, which revokes every
	# descriptor already open on it: a report that had not finished by then
	# lost the rest of its output, and with it the CLI-END marker. Short
	# reports won that race; the program probes, which run for minutes,
	# cannot.
	{
		echo '#!/bin/sh'
		echo 'report() {'
		echo 'echo "===CLI-MARKER==="'
		# printf, not echo: dash's echo interprets backslash escapes, so a
		# sed or awk expression in REPORT arrives with its backslashes eaten
		# and silently matches nothing. That cost a failing check that looked
		# like a broken cheatcode and was a broken test.
		printf '%s\n' "$REPORT"
		echo 'echo "===CLI-END==="'
		echo '}'
		echo 'report 2>&1 | while IFS= read -r l; do echo "$l" > /dev/ttyS0; done'
	} > "$WORK/iso/live/rootcopy/usr/local/bin/rcli"
	printf '#!/bin/sh\necho "===GUI-MARKER===" > /dev/ttyS0\n' \
		> "$WORK/iso/live/rootcopy/usr/local/bin/rgui"
	chmod +x "$WORK/iso/live/rootcopy/usr/local/bin/rcli" \
	         "$WORK/iso/live/rootcopy/usr/local/bin/rgui"
	# The initrd copies rootcopy onto the union with cp -a, which gives the
	# union's /usr the mtime of rootcopy/usr - the moment this test made it.
	# That is newer than the image's update-done stamp, so every test boot
	# would run ldconfig.service and look like an image that ships without
	# the stamp. A real boot has an empty rootcopy. Date these directories
	# in the past so the union's /usr keeps an old mtime, as it does then.
	find "$WORK/iso/live/rootcopy" -type d -exec touch -d 2000-01-01 {} +

	# A test that needs more than rcli/rgui on the medium - a config file
	# delivered through rootcopy, say - defines bt_extra_setup and gets its
	# hands on $WORK/iso before the image is closed.
	command -v bt_extra_setup >/dev/null 2>&1 && bt_extra_setup

	BT_CMDLINE="console=ttyS0,115200 from=/ $([ "$BASE_ONLY" = 1 ] && echo base_only) $CODES cliexec=/usr/local/bin/rcli guiexec=/usr/local/bin/rgui"
	cat >> "$WORK/iso/isolinux/live.cfg" <<EOF

label BOOT-TEST
menu default
kernel /live/vmlinuz1
append initrd=/live/initrd1.xz $BT_CMDLINE
EOF
	# The shipped EFI grub carries a chooser that looks for /grub.cfg,
	# /boot/grub.cfg and /boot/grub/grub.cfg in that order on every device,
	# so from an ISO it is the root grub.cfg that gets used and from a USB
	# stick laid out by hand it may be the other. The test entry goes first
	# in every one that exists, with a short timeout.
	for g in "$WORK/iso/grub.cfg" "$WORK/iso/boot/grub.cfg" "$WORK/iso/boot/grub/grub.cfg"; do
		[ -f "$g" ] || continue
		{ printf 'set default=0\nset timeout=2\nmenuentry "BOOT-TEST" {\nlinux /live/vmlinuz1 %s\ninitrd /live/initrd1.xz\n}\n' "$BT_CMDLINE"
		  cat "$g"; } > "$g.new" && mv "$g.new" "$g"
	done
	EFI_OPTS=""
	[ -f "$WORK/iso/efiboot.img" ] && EFI_OPTS="-eltorito-alt-boot -e efiboot.img -no-emul-boot -isohybrid-gpt-basdat"
	case "$FIRMWARE" in uefi*) [ -z "$EFI_OPTS" ] && bt_fail "FIRMWARE=$FIRMWARE but $ISODATA has no efiboot.img - build with ISOUEFI=TRUE" ;; esac

	# shellcheck disable=SC2086
	( cd "$WORK/iso" && xorriso -as mkisofs -r -J -joliet-long -l \
	    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin -partition_offset 16 \
	    -V boottest -b isolinux/isolinux.bin -c isolinux/boot.cat \
	    -no-emul-boot -boot-load-size 4 -boot-info-table $EFI_OPTS \
	    -o "$WORK/boot-test.iso" . ) >"$WORK/xorriso.log" 2>&1 \
	    || bt_fail "xorriso failed, see $WORK/xorriso.log"

	[ "$SCRATCH" = 1 ] && bt_scratch_disk
}

# A disk for the guest to find, so the mount options it chooses can be
# observed.  Left dirty-free and unremarkable on purpose.
#
# It is *partitioned*, with the filesystem on partition 1 rather than on the
# whole disk, because that is the only layout that exercises the initrd's
# partition enumeration.  An earlier whole-disk version of this test passed
# while forensic was silently leaving every partition writable: with nothing
# to enumerate, the broken enumeration was never reached.
bt_scratch_disk() {
	# The partition is built as a filesystem image in its own right and then
	# copied into place at the partition offset.  The obvious route -
	# losetup -P on the assembled disk - needs a kernel whose loop driver
	# scans partitions, which build containers frequently do not have, and
	# skipping the test there would quietly turn this into no test at all.
	mkfs.ext4 -q -F -L SCRATCH "$WORK/part1.img" 63M >/dev/null 2>&1 \
		|| bt_skip "mkfs.ext4 not available"
	mkdir -p "$WORK/mnt" && mount -o loop "$WORK/part1.img" "$WORK/mnt" 2>/dev/null && {
		mkdir -p "$WORK/mnt/magicsrc"
		echo "from the scratch disk" > "$WORK/mnt/magicsrc/hello"
		umount "$WORK/mnt"; }
	rmdir "$WORK/mnt" 2>/dev/null

	dd if=/dev/zero of="$WORK/scratch.img" bs=1M count=64 status=none
	# A DOS partition table written by hand: one Linux partition starting at
	# LBA 2048 and running for 129024 sectors (63MiB).  sfdisk is not
	# installed everywhere and this is 18 bytes.
	printf '\000\376\377\377\203\376\377\377\000\010\000\000\000\370\001\000' \
		| dd of="$WORK/scratch.img" bs=1 seek=446 conv=notrunc status=none
	printf '\125\252' \
		| dd of="$WORK/scratch.img" bs=1 seek=510 conv=notrunc status=none
	dd if="$WORK/part1.img" of="$WORK/scratch.img" bs=512 seek=2048 \
		conv=notrunc status=none
	rm -f "$WORK/part1.img"
}

bt_boot() {
	echo "== booting (cliexec budget ${CLI_TIMEOUT}s, guiexec budget ${GUI_TIMEOUT}s)"
	SER="$WORK/serial.log"; : > "$SER"; rm -f "$MON"
	DISK=""
	[ "$SCRATCH" = 1 ] && DISK="-drive file=$WORK/scratch.img,format=raw,if=ide,index=1"
	FW=""
	case "$FIRMWARE" in uefi*)
		[ -r "$OVMF_CODE" ] || bt_skip "no OVMF firmware at $OVMF_CODE"
		cp -f "$OVMF_VARS" "$WORK/OVMF_VARS.fd"
		FW="-drive if=pflash,format=raw,readonly=on,file=$OVMF_CODE -drive if=pflash,format=raw,file=$WORK/OVMF_VARS.fd"
		# the secboot firmware needs a machine with SMM for its variable store
		[ "$FIRMWARE" = uefi-secure ] && FW="-machine q35,smm=on -global driver=cfi.pflash01,property=secure,value=on $FW"
		echo "   firmware: $FIRMWARE ($OVMF_CODE)" ;;
	esac
	# shellcheck disable=SC2086
	qemu-system-x86_64 -accel tcg,thread=multi,tb-size=1024 -m 3072 -smp 4 $FW \
	  -cdrom "$WORK/boot-test.iso" -boot d $DISK -display none -vga std \
	  -monitor unix:"$MON",server,nowait -serial file:"$SER" -no-reboot \
	  > "$WORK/qemu.log" 2>&1 &
	QPID=$!
	trap 'kill $QPID 2>/dev/null' EXIT INT TERM

	start=$(date +%s); cli=""; gui=""
	while :; do
		now=$(( $(date +%s) - start ))
		[ -z "$cli" ] && grep -q "CLI-END" "$SER" 2>/dev/null && { cli=$now; echo "   cliexec stage at ${cli}s"; }
		[ -z "$gui" ] && grep -q "GUI-MARKER" "$SER" 2>/dev/null && { gui=$now; echo "   guiexec stage at ${gui}s"; }
		# both stages, in whichever order: a report that runs for minutes
		# at the cliexec stage is still going when the desktop comes up
		[ -n "$cli" ] && [ -n "$gui" ] && break
		kill -0 $QPID 2>/dev/null || { echo "   qemu exited early"; break; }
		# a test that must act while the guest runs - a screenshot the
		# moment a window fails to appear - defines bt_poll
		command -v bt_poll >/dev/null 2>&1 && bt_poll
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

#!/bin/sh
# Does our linuxrc actually boot a systemd Debian?
#
# Every other test in this directory checks what linuxrc *writes*. This one
# checks the claim the whole branch rests on: that a Porteus-lineage initrd can
# assemble a union and hand off to systemd as PID 1, and that the cheatcodes
# rewritten for systemd take effect on a real system.
#
# There is no systemd rootfs in this repo to test against - build-trixie
# produces Devuan with sysvinit, which is the reason this branch exists. So the
# test borrows one: it takes the squashfs modules and kernel from a MiniOS ISO
# (Debian 13 trixie, systemd 257) and boots them with OUR initrd instead of
# theirs. That is a sharper test than using our own image would be, because
# nothing in the rootfs was built to accommodate us.
#
# The kernel version has to match the modules inside our initrd, which is why
# the ISO's own vmlinuz is used rather than ours. Both happen to be
# 6.12.101+deb13-amd64; the test checks rather than assumes.
#
#     ./tests/linuxrc/boot-test-systemd.sh [/path/to/minios.iso]
set -u

BT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$BT_DIR/../.." && pwd)
WORK=${WORK:-/tmp/linuxrc-systemd}
MON=/tmp/lsd.sock
CLI_TIMEOUT=${CLI_TIMEOUT:-420}

pass=0; bad=0
_pass() { echo "   PASS  $1"; pass=$((pass+1)); }
_fail() { echo "   FAIL  $1"; shift; [ $# -gt 0 ] && echo "         $*"; bad=$((bad+1)); }
skip()  { echo "SKIP: $*"; exit 0; }
die()   { echo "FAIL: $*"; exit 1; }

command -v qemu-system-x86_64 >/dev/null || skip "qemu-system-x86_64 not installed"
command -v xorriso >/dev/null || skip "xorriso not installed"
command -v cpio >/dev/null || skip "cpio not installed"

ISO=${1:-$(ls /workspace/minios-linux/minios-live/build/iso/*.iso 2>/dev/null | tail -1)}
[ -n "$ISO" ] && [ -f "$ISO" ] || skip "no MiniOS ISO - run ./minios/build-minios first"
OURIRD=${OURIRD:-$REPO/trixie/isodata/live/initrd1.xz}
[ -f "$OURIRD" ] || skip "no built initrd at $OURIRD - run build-trixie first"

rm -rf "$WORK"; mkdir -p "$WORK/iso/live" "$WORK/src"; rm -f "$MON"

echo "== taking the rootfs from $(basename "$ISO")"
xorriso -osirrox on -indev "$ISO" -extract /minios "$WORK/src" >/dev/null 2>&1 \
	|| die "could not extract the ISO"

KVER=$(ls "$WORK/src"/*kernel*.sb 2>/dev/null | sed -n 's/.*01-kernel-\(.*\)\.sb/\1/p')
[ -n "$KVER" ] || die "could not work out the kernel version from the modules"
echo "   rootfs kernel: $KVER"

# Our initrd only carries modules for the kernel it was built against. If that
# is not the kernel we are about to boot, squashfs will not even load and the
# failure will look like a linuxrc bug rather than a mismatch.
IRDVER=$(xz -dc "$OURIRD" | cpio -t --quiet 2>/dev/null | sed -n 's|^lib/modules/\([^/]*\)/.*|\1|p' | head -1)
echo "   our initrd carries modules for: ${IRDVER:-none}"
[ "$KVER" = "$IRDVER" ] || die "kernel mismatch: rootfs $KVER, initrd $IRDVER - rebuild one of them"

echo "== assembling a hybrid image: their rootfs, our initrd"
cp "$WORK/src/boot/vmlinuz-$KVER" "$WORK/iso/live/vmlinuz1"
# .sb is squashfs under another name; linuxrc looks for *.squashfs and loads
# them in sorted order, which the numeric prefixes already give us.
for m in "$WORK/src"/*.sb; do
	cp "$m" "$WORK/iso/live/$(basename "${m%.sb}").squashfs"
done
echo "   modules: $(ls "$WORK/iso/live"/*.squashfs | wc -l)"

# Our initrd, repacked around the working tree, so this tests the branch rather
# than whatever was in the last full build.
IRD="$WORK/ird"; mkdir -p "$IRD"
( cd "$IRD" && xz -dc "$OURIRD" | cpio -idm --quiet 2>/dev/null ) || die "could not unpack our initrd"
for f in linuxrc finit modlist; do
	[ -f "$REPO/initrd-src/$f" ] && cp -f "$REPO/initrd-src/$f" "$IRD/$f"
done
chmod +x "$IRD/linuxrc"
( cd "$IRD" && find . | cpio -o -H newc --quiet 2>/dev/null | xz -f --check=crc32 ) \
	> "$WORK/iso/live/initrd1.xz" || die "could not repack our initrd"

# The report goes in through rootcopy, which also proves rootcopy still works
# against a rootfs that knows nothing about us.
mkdir -p "$WORK/iso/live/rootcopy/usr/local/bin"
cat > "$WORK/iso/live/rootcopy/usr/local/bin/rcli" <<'RCLI'
#!/bin/sh
exec > /dev/ttyS0 2>&1
echo "===CLI-MARKER==="
echo "INIT=$(ps -p 1 -o comm=)"
echo "OSID=$(. /etc/os-release; echo $ID-$VERSION_ID)"
echo "SHUTDOWN=$(test -x /run/initramfs/shutdown && echo PRESENT || echo MISSING)"
echo "MNTLIVE=$(readlink /mnt/live 2>/dev/null || echo NOTALINK)"
# readlink only reads the link text; it says nothing about the target being
# there. /run is a mountpoint in its own right when the pivot was done right,
# and empty when systemd's tmpfs went over the top of it.
echo "INITRAMFSN=$(ls /run/initramfs 2>/dev/null | wc -l)"
echo "RUNMOUNT=$(awk '$2=="/run"{print $3}' /proc/mounts | head -1)"
echo "SQFS=$(grep -c squashfs /proc/mounts)"
echo "UNION=$(grep -c overlay /proc/mounts)"
echo "XORG=$(pgrep -c -x Xorg 2>/dev/null || true)"
echo "UNITENABLED=$(test -L /etc/systemd/system/multi-user.target.wants/cliexec-cheat.service && echo YES || echo NO)"
echo "GETTYDROPIN=$(test -f /etc/systemd/system/getty@tty1.service.d/90-autologin.conf && echo YES || echo NO)"
echo "AUTOLOGINUSER=$(sed -n 's/.*--autologin \([^ ]*\).*/\1/p' /etc/systemd/system/getty@tty1.service.d/90-autologin.conf 2>/dev/null)"
echo "BTMASK=$(readlink /etc/systemd/system/bluetooth.service 2>/dev/null || echo NOTMASKED)"
echo "CUPSMASK=$(readlink /etc/systemd/system/cups.service 2>/dev/null || echo NOTMASKED)"
echo "DEFTARGET=$(readlink /etc/systemd/system/default.target 2>/dev/null || echo UNSET)"
echo "CLIRAN=$(test -f /tmp/cliexec-ran && echo YES || echo NO)"
echo "===CLI-END==="
RCLI
chmod +x "$WORK/iso/live/rootcopy/usr/local/bin/rcli"

mkdir -p "$WORK/iso/isolinux"
cp /usr/lib/ISOLINUX/isolinux.bin "$WORK/iso/isolinux/" 2>/dev/null
for m in ldlinux.c32 libcom32.c32 libutil.c32; do
	cp /usr/lib/syslinux/modules/bios/$m "$WORK/iso/isolinux/" 2>/dev/null
done
# console=ttyS0 is ours to add here: unlike the MiniOS smoke test, this is our
# own boot line for our own initrd, so reading the serial port is fair game.
# One line, no continuations: isolinux has no line-continuation syntax, so a
# trailing backslash is passed through as a literal argument and everything
# after it is silently dropped. The first run of this test lost every cheatcode
# that way and looked like linuxrc ignoring them.
cat > "$WORK/iso/isolinux/isolinux.cfg" <<EOF
DEFAULT live
PROMPT 0
TIMEOUT 10
LABEL live
  KERNEL /live/vmlinuz1
  APPEND initrd=/live/initrd1.xz console=ttyS0,115200 from=/ nomagic login=root disable-services=cups nobluetooth default-target=multi-user.target cliexec=touch~/tmp/cliexec-ran;/usr/local/bin/rcli
EOF

( cd "$WORK/iso" && xorriso -as mkisofs -r -J -l \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin -partition_offset 16 \
    -V systest -b isolinux/isolinux.bin -c isolinux/boot.cat \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    -o "$WORK/test.iso" . ) >"$WORK/xorriso.log" 2>&1 \
    || die "xorriso failed, see $WORK/xorriso.log"

echo "== booting (budget ${CLI_TIMEOUT}s, emulated)"
SER="$WORK/serial.log"; : > "$SER"
qemu-system-x86_64 -accel tcg,thread=multi,tb-size=1024 -m 4096 -smp 4 \
  -cdrom "$WORK/test.iso" -boot d -display none -vga std \
  -monitor unix:"$MON",server,nowait -serial file:"$SER" -no-reboot \
  > "$WORK/qemu.log" 2>&1 &
QPID=$!
trap 'kill $QPID 2>/dev/null' EXIT INT TERM

start=$(date +%s); cli=""
while :; do
	now=$(( $(date +%s) - start ))
	grep -q "CLI-END" "$SER" 2>/dev/null && { cli=$now; echo "   report at ${cli}s"; break; }
	kill -0 $QPID 2>/dev/null || { echo "   qemu exited early"; break; }
	[ "$now" -ge "$CLI_TIMEOUT" ] && break
	sleep 5
done
kill $QPID 2>/dev/null; wait $QPID 2>/dev/null
# The guest writes to a tty, so \n becomes \r\n and any $-anchored pattern
# silently never matches.
tr -d '\r' < "$SER" > "$SER.clean"

echo "== results"
[ -n "$cli" ] || die "no report within ${CLI_TIMEOUT}s (see $SER.clean)"
sed -n '/===CLI-MARKER===/,/===CLI-END===/p' "$SER.clean" | sed 's/^/   | /'
get() { sed -n "s/^$1=//p" "$SER.clean" | head -1; }

echo
_pass "our initrd booted their rootfs and reached userspace (${cli}s)"

echo "-- the handoff"
[ "$(get INIT)" = systemd ] && _pass "PID 1 is systemd" \
	|| _fail "PID 1 is systemd" "got '$(get INIT)'"
case "$(get OSID)" in debian-13*) _pass "the rootfs is Debian 13 trixie" ;;
	*) _fail "the rootfs is Debian 13 trixie" "got '$(get OSID)'" ;; esac
# The reason the pivot target changed. Without this systemd has nowhere to
# stand while unmounting the union at shutdown.
[ "$(get SHUTDOWN)" = PRESENT ] && _pass "the shutdown handler is at /run/initramfs" \
	|| _fail "the shutdown handler is at /run/initramfs" "got '$(get SHUTDOWN)'"
[ "$(get MNTLIVE)" = /run/initramfs ] && _pass "/mnt/live points at the pivoted root" \
	|| _fail "/mnt/live points at the pivoted root" "got '$(get MNTLIVE)'"
# The symlink above can be right while the target is empty, which is exactly
# what happened when systemd's tmpfs was allowed over /run. This is the check
# that /mnt/live leads somewhere.
[ "$(get INITRAMFSN)" -gt 0 ] 2>/dev/null \
	&& _pass "and the old root is really there ($(get INITRAMFSN) entries)" \
	|| _fail "the old root is really there" "/run/initramfs is empty"
[ -n "$(get RUNMOUNT)" ] && _pass "/run is a mountpoint, so systemd left it alone ($(get RUNMOUNT))" \
	|| _fail "/run is a mountpoint" "nothing mounted on /run"

echo "-- the union our linuxrc assembled"
[ "$(get SQFS)" -gt 0 ] 2>/dev/null && _pass "squashfs modules are mounted ($(get SQFS))" \
	|| _fail "squashfs modules are mounted" "none in /proc/mounts"
[ "$(get UNION)" -gt 0 ] 2>/dev/null && _pass "unioned with overlayfs" \
	|| _fail "unioned with overlayfs" "no overlay in /proc/mounts"

echo "-- the cheatcodes, on a rootfs that knows nothing about them"
[ "$(get CLIRAN)" = YES ] && _pass "cliexec= commands ran" \
	|| _fail "cliexec= commands ran" "the flag file is absent"
[ "$(get UNITENABLED)" = YES ] && _pass "and by way of an enabled unit, not rc.local" \
	|| _fail "cliexec runs from an enabled unit" "no symlink in multi-user.target.wants"
[ "$(get GETTYDROPIN)" = YES ] && _pass "login= wrote a getty drop-in" \
	|| _fail "login= wrote a getty drop-in" "no drop-in"
[ "$(get AUTOLOGINUSER)" = root ] && _pass "naming the user asked for" \
	|| _fail "the drop-in names the right user" "got '$(get AUTOLOGINUSER)'"
[ "$(get BTMASK)" = /dev/null ] && _pass "nobluetooth masked bluetooth.service" \
	|| _fail "nobluetooth masked bluetooth.service" "got '$(get BTMASK)'"
[ "$(get CUPSMASK)" = /dev/null ] && _pass "disable-services= masked cups.service" \
	|| _fail "disable-services= masked cups.service" "got '$(get CUPSMASK)'"
case "$(get DEFTARGET)" in *multi-user.target) _pass "default-target= repointed default.target" ;;
	*) _fail "default-target= repointed default.target" "got '$(get DEFTARGET)'" ;; esac
# multi-user.target was asked for, so the desktop must NOT have come up. This is
# the check that default-target= did something rather than being ignored.
[ "$(get XORG)" = 0 ] || [ -z "$(get XORG)" ] && _pass "and the desktop did not start, as asked" \
	|| _fail "the desktop did not start" "Xorg count is '$(get XORG)'"

echo
if [ "$bad" -eq 0 ]; then
	echo "systemd boot test passed: $pass checks, report at ${cli}s"
else
	echo "systemd boot test FAILED: $bad of $((pass+bad)) checks (serial: $SER.clean)"
	exit 1
fi

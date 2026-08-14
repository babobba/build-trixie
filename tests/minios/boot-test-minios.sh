#!/bin/sh
# Does the MiniOS ISO actually run?
#
# This is a smoke test of an unmodified upstream build, not a test of any of our
# code. The point is to establish that a Debian-trixie live system with systemd
# as PID 1 boots from a Porteus-ancestor shell-script initrd, since that is the
# combination our own image cannot currently produce.
#
# Nothing is added to the boot line. Our own boot tests append
# console=ttyS0,115200 and read the serial port, but doing that here would mean
# testing a boot line MiniOS does not ship, and "runs in its default state" is
# exactly the claim being checked. So the guest is questioned over SSH instead,
# which MiniOS enables by default (ENABLE_SERVICES="ssh"), through a forwarded
# port on QEMU's user network. A screenshot is taken as well, because SSH proves
# systemd came up but not that anything reached the screen.
#
#     ./tests/minios/boot-test-minios.sh [/path/to/minios.iso]
set -u

BT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$BT_DIR/../.." && pwd)
SRC=${SRC:-/workspace/minios-linux/minios-live}
WORK=${WORK:-/tmp/minios-boot}
MON=/tmp/minios-mon.sock          # QEMU rejects socket paths over 107 bytes
SSH_PORT=${SSH_PORT:-2222}
BOOT_TIMEOUT=${BOOT_TIMEOUT:-420}
# Defaults documented in linux-live/build.conf.
USER=${USER_NAME:-live}
PASS=${USER_PASS:-evil}

pass=0; bad=0
_pass() { echo "   PASS  $1"; pass=$((pass+1)); }
_fail() { echo "   FAIL  $1"; shift; [ $# -gt 0 ] && echo "         $*"; bad=$((bad+1)); }
skip()  { echo "SKIP: $*"; exit 0; }
die()   { echo "FAIL: $*"; exit 1; }

command -v qemu-system-x86_64 >/dev/null || skip "qemu-system-x86_64 not installed"
command -v sshpass >/dev/null || skip "sshpass not installed"

ISO=${1:-}
if [ -z "$ISO" ]; then
	ISO=$(find "$SRC" -name '*.iso' -type f 2>/dev/null | sort | tail -1)
fi
[ -n "$ISO" ] && [ -f "$ISO" ] || skip "no MiniOS ISO found - run ./minios/build-minios first"
echo "== ISO: $ISO ($(du -h "$ISO" | cut -f1))"

rm -rf "$WORK"; mkdir -p "$WORK"; rm -f "$MON"

# 4 GB: the default build is a full Xfce desktop, and under TCG with no KVM a
# tighter allocation puts it into swap before the session is up.
echo "== booting (budget ${BOOT_TIMEOUT}s, no KVM so this is emulated)"
qemu-system-x86_64 -accel tcg,thread=multi,tb-size=1024 -m 4096 -smp 4 \
  -cdrom "$ISO" -boot d -display none -vga std \
  -netdev user,id=n0,hostfwd=tcp::${SSH_PORT}-:22 -device e1000,netdev=n0 \
  -monitor unix:"$MON",server,nowait -no-reboot \
  > "$WORK/qemu.log" 2>&1 &
QPID=$!
trap 'kill $QPID 2>/dev/null' EXIT INT TERM

SSHOPT="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 -o PreferredAuthentications=password \
        -o PubkeyAuthentication=no -o LogLevel=ERROR"

guest() { sshpass -p "$PASS" ssh $SSHOPT -p "$SSH_PORT" "$USER@127.0.0.1" "$@" 2>/dev/null; }

start=$(date +%s); up=""
while :; do
	now=$(( $(date +%s) - start ))
	if [ -z "$up" ] && guest true; then up=$now; echo "   SSH answered at ${up}s"; break; fi
	kill -0 $QPID 2>/dev/null || { echo "   qemu exited early"; break; }
	[ "$now" -ge "$BOOT_TIMEOUT" ] && break
	sleep 5
done

# A screenshot regardless of how SSH went: if the boot failed this is the only
# evidence of where it stopped, and if it succeeded it is the only evidence that
# anything reached the display.
if [ -S "$MON" ]; then
	printf 'screendump %s\n' "$WORK/screen.ppm" | timeout 20 socat - UNIX-CONNECT:"$MON" >/dev/null 2>&1 \
		|| printf 'screendump %s\n' "$WORK/screen.ppm" | timeout 20 nc -U "$MON" >/dev/null 2>&1
	sleep 2
	[ -f "$WORK/screen.ppm" ] && command -v convert >/dev/null \
		&& convert "$WORK/screen.ppm" "$WORK/screen.png" 2>/dev/null
fi

echo "== results"
[ -n "$up" ] || {
	kill $QPID 2>/dev/null
	die "the guest never answered SSH within ${BOOT_TIMEOUT}s (see $WORK/qemu.log, $WORK/screen.ppm)"
}
_pass "the system booted and SSH answered (${up}s)"

# Everything below is read from the running guest. Collected in one go so a
# dropped connection cannot make half the checks silently vacuous.
guest 'echo "INIT=$(ps -p 1 -o comm=)";
       echo "SYSTEMD=$(systemctl --version 2>/dev/null | head -1)";
       echo "STATE=$(systemctl is-system-running 2>&1)";
       echo "TARGET=$(systemctl get-default 2>&1)";
       echo "OSID=$(. /etc/os-release; echo $ID-$VERSION_ID)";
       echo "OSNAME=$(. /etc/os-release; echo $PRETTY_NAME)";
       echo "XORG=$(pgrep -c -x Xorg 2>/dev/null || echo 0)";
       echo "GRAPHICAL=$(systemctl is-active graphical.target 2>&1)";
       echo "UNION=$(grep -c overlay /proc/mounts)";
       echo "INITRD=$(ls /run/initramfs 2>/dev/null | tr "\n" " ")";
       echo "SQFS=$(grep -c squashfs /proc/mounts)"' > "$WORK/report" 2>/dev/null

cat "$WORK/report" | sed 's/^/   | /'
get() { sed -n "s/^$1=//p" "$WORK/report"; }

[ -n "$(get INIT)" ] || _fail "the guest answered but reported nothing" "SSH worked, the query did not"

case "$(get INIT)" in
	systemd) _pass "PID 1 is systemd" ;;
	*)       _fail "PID 1 is systemd" "PID 1 is '$(get INIT)'" ;;
esac
case "$(get OSID)" in
	debian-13*) _pass "the base is Debian 13 trixie" ;;
	*)          _fail "the base is Debian 13 trixie" "os-release says '$(get OSID)'" ;;
esac
case "$(get STATE)" in
	running)  _pass "systemd reports the system as running" ;;
	degraded) _pass "systemd is up, some units failed (degraded)" ;;
	*)        _fail "systemd finished starting up" "is-system-running: $(get STATE)" ;;
esac
case "$(get TARGET)" in
	graphical.target) _pass "the default target is graphical.target" ;;
	*)                _fail "the default target is graphical.target" "got '$(get TARGET)'" ;;
esac
case "$(get GRAPHICAL)" in
	active) _pass "graphical.target is active" ;;
	*)      _fail "graphical.target is active" "got '$(get GRAPHICAL)'" ;;
esac
[ "$(get XORG)" -gt 0 ] 2>/dev/null \
	&& _pass "an X server is running" \
	|| _fail "an X server is running" "pgrep -c Xorg returned '$(get XORG)'"

# The live-system machinery, as opposed to just "Debian booted".
[ "$(get SQFS)" -gt 0 ] 2>/dev/null \
	&& _pass "squashfs modules are mounted" \
	|| _fail "squashfs modules are mounted" "no squashfs in /proc/mounts"
[ "$(get UNION)" -gt 0 ] 2>/dev/null \
	&& _pass "the union is overlayfs" \
	|| _fail "the union is overlayfs" "no overlay in /proc/mounts"
# The whole reason systemd and this initrd coexist: LiveKit pivots the old root
# to /run/initramfs, which is where systemd looks for a shutdown handler.
case "$(get INITRD)" in
	"") _fail "the old root is at /run/initramfs" "it is empty - the pivot target differs" ;;
	*)  _pass "the old root is preserved at /run/initramfs ($(get INITRD))" ;;
esac

kill $QPID 2>/dev/null; wait $QPID 2>/dev/null

echo
[ -f "$WORK/screen.png" ] && echo "screenshot: $WORK/screen.png"
[ -f "$WORK/screen.ppm" ] && echo "screenshot: $WORK/screen.ppm"
if [ "$bad" -eq 0 ]; then
	echo "MiniOS boot test passed: $pass checks, SSH up at ${up}s"
else
	echo "MiniOS boot test FAILED: $bad of $((pass+bad)) checks"
	exit 1
fi

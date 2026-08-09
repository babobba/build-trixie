#!/bin/sh
# End-to-end boot test for the initrd cheatcodes.
#
# Builds a throwaway ISO from a built isodata tree, boots it under QEMU, and
# checks that the guest reaches both cheatcode stages and that the codes did
# what they claim.  The guest reports over the serial port rather than to the
# screen, so the test can tell *when* something happened and does not depend on
# a desktop having finished painting.
#
#   usage: boot-test.sh [isodata-dir]        (default: <repo>/trixie/isodata)
#
# Budgets, seconds from power-on.  Measured on an emulated host with no KVM:
# cliexec is reached in 85-110s and guiexec in ~145s, so these leave generous
# headroom for a slower machine or a fuller module set.  Override with the
# environment variables if a host needs more.
CLI_TIMEOUT=${CLI_TIMEOUT:-180}
GUI_TIMEOUT=${GUI_TIMEOUT:-240}

set -u
TESTDIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$TESTDIR/../.." && pwd)
ISODATA=${1:-$REPO/trixie/isodata}
WORK=${WORK:-/tmp/linuxrc-boot-test}
# QEMU rejects UNIX socket paths over 107 bytes, so keep the monitor short.
MON=/tmp/lbt-mon.sock

fail() { echo "FAIL: $*"; exit 1; }

command -v qemu-system-x86_64 >/dev/null || { echo "SKIP: qemu-system-x86_64 not installed"; exit 0; }
command -v xorriso >/dev/null || { echo "SKIP: xorriso not installed"; exit 0; }
[ -d "$ISODATA/live" ] || fail "no isodata at $ISODATA - run build-trixie first"
[ -f "$ISODATA/live/initrd1.xz" ] || fail "$ISODATA has no initrd1.xz"

echo "== building test ISO from $ISODATA"
rm -rf "$WORK"; mkdir -p "$WORK"
cp -a "$ISODATA" "$WORK/iso" || fail "could not copy isodata"
mkdir -p "$WORK/iso/live/rootcopy/usr/local/bin"

# Reports what the initrd actually wrote, before X starts.
cat > "$WORK/iso/live/rootcopy/usr/local/bin/rcli" <<'EOF'
#!/bin/sh
exec > /dev/ttyS0 2>&1
echo "===CLI-MARKER==="
# pgrep -c prints 0 and exits non-zero when nothing matches, so a `|| echo 0`
# fallback would print the count twice.
xorg=$(pgrep -c Xorg 2>/dev/null)
echo "XORG_RUNNING=${xorg:-0}"
grep XKBLAYOUT /etc/default/keyboard 2>/dev/null || echo 'XKBLAYOUT=MISSING'
echo "TZFILE=$(cat /etc/timezone 2>/dev/null || echo MISSING)"
echo "LOCALTIME=$(readlink /etc/localtime 2>/dev/null || echo MISSING)"
echo "ADJTIME=$(tail -1 /etc/adjtime 2>/dev/null || echo MISSING)"
echo "ZRAM=$(swapon -s 2>/dev/null | grep -c zram)"
echo "===CLI-END==="
EOF
# Runs from the desktop session, proving the autostart entry points work.
cat > "$WORK/iso/live/rootcopy/usr/local/bin/rgui" <<'EOF'
#!/bin/sh
echo "===GUI-MARKER===" > /dev/ttyS0
EOF
chmod +x "$WORK/iso/live/rootcopy/usr/local/bin/rcli" "$WORK/iso/live/rootcopy/usr/local/bin/rgui"

cat >> "$WORK/iso/isolinux/live.cfg" <<'EOF'

label BOOT-TEST
menu default
kernel /live/vmlinuz1
append initrd=/live/initrd1.xz from=/ base_only kmap=fr timezone=Europe/Amsterdam utc zram=25 cliexec=/usr/local/bin/rcli guiexec=/usr/local/bin/rgui
EOF

( cd "$WORK/iso" && xorriso -as mkisofs -r -J -joliet-long -l \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin -partition_offset 16 \
    -V boottest -b isolinux/isolinux.bin -c isolinux/boot.cat \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    -o "$WORK/boot-test.iso" . ) >"$WORK/xorriso.log" 2>&1 \
    || fail "xorriso failed, see $WORK/xorriso.log"

echo "== booting (cliexec budget ${CLI_TIMEOUT}s, guiexec budget ${GUI_TIMEOUT}s)"
SER="$WORK/serial.log"; : > "$SER"; rm -f "$MON"
qemu-system-x86_64 -accel tcg,thread=multi,tb-size=1024 -m 3072 -smp 4 \
  -cdrom "$WORK/boot-test.iso" -boot d -display none -vga std \
  -monitor unix:"$MON",server,nowait -serial file:"$SER" -no-reboot \
  > "$WORK/qemu.log" 2>&1 &
QPID=$!
trap 'kill $QPID 2>/dev/null' EXIT INT TERM

start=$(date +%s)
cli=""; gui=""
while :; do
    now=$(( $(date +%s) - start ))
    [ -z "$cli" ] && grep -q "CLI-END" "$SER" 2>/dev/null && { cli=$now; echo "   cliexec stage at ${cli}s"; }
    [ -z "$gui" ] && grep -q "GUI-MARKER" "$SER" 2>/dev/null && { gui=$now; echo "   guiexec stage at ${gui}s"; break; }
    if ! kill -0 $QPID 2>/dev/null; then echo "   qemu exited early"; break; fi
    [ -z "$cli" ] && [ "$now" -ge "$CLI_TIMEOUT" ] && break
    [ "$now" -ge "$GUI_TIMEOUT" ] && break
    sleep 3
done
kill $QPID 2>/dev/null; wait $QPID 2>/dev/null

echo "== results"
[ -n "$cli" ] || fail "cliexec stage not reached within ${CLI_TIMEOUT}s (see $SER)"
[ -n "$gui" ] || fail "guiexec stage not reached within ${GUI_TIMEOUT}s (see $SER)"

pass=0; bad=0
# The guest writes to a tty, so the line discipline turns every \n into \r\n.
# Strip the carriage returns or any pattern anchored with $ silently never
# matches -- which looks like a failing cheatcode rather than a broken test.
tr -d '\r' < "$SER" > "$SER.clean"
check() {   # DESC PATTERN
    if grep -q -- "$2" "$SER.clean"; then echo "   PASS  $1"; pass=$((pass+1))
    else echo "   FAIL  $1 (wanted /$2/)"; bad=$((bad+1)); fi
}
check "cliexec ran before X started"     '^XORG_RUNNING=0$'
check "kmap= set the keyboard layout"    '^XKBLAYOUT="fr"$'
check "timezone= wrote /etc/timezone"    '^TZFILE=Europe/Amsterdam$'
check "timezone= relinked /etc/localtime" '^LOCALTIME=.*Europe/Amsterdam$'
check "utc wrote /etc/adjtime"           '^ADJTIME=UTC$'
check "zram= created a swap device"      '^ZRAM=[1-9]'

echo
if [ "$bad" -eq 0 ]; then
    echo "boot test passed: $pass checks, cliexec ${cli}s, guiexec ${gui}s"
else
    echo "boot test FAILED: $bad of $((pass+bad)) checks failed (serial log: $SER)"
    exit 1
fi

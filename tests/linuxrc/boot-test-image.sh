#!/bin/sh
# Does the image this repo builds boot, with this branch's initrd?
#
# boot-test-systemd.sh answers the same question using MiniOS's rootfs, which
# was the only systemd rootfs available before configs-trixie/default-systemd.conf
# existed. This one uses ours: build with
#
#     ./build-trixie configs-trixie/default-systemd.conf
#
# and the isodata it leaves behind is what gets booted here. Both tests are
# worth keeping - theirs proves the initrd works against a rootfs that knows
# nothing about us, this one proves the config we ship produces a system that
# actually starts.
#
# The cheatcodes on the boot line are the ones the systemd port rewrote, so a
# regression in any of them fails here as well as in the unit tests.
NAME=${NAME:-image}
CODES="${CODES:-login=root disable-services=cups nobluetooth}"
REPORT='
echo "INIT=$(ps -p 1 -o comm=)"
echo "OSID=$(. /etc/os-release; echo $ID-$VERSION_ID)"
echo "SHUTDOWN=$(test -x /run/initramfs/shutdown && echo PRESENT || echo MISSING)"
echo "INITRAMFSN=$(ls /run/initramfs 2>/dev/null | wc -l)"
echo "RUNMOUNT=$(awk "\$2==\"/run\"{print \$3}" /proc/mounts | head -1)"
echo "SQFS=$(grep -c squashfs /proc/mounts)"
echo "UNION=$(grep -c overlay /proc/mounts)"
echo "UNITENABLED=$(test -L /etc/systemd/system/multi-user.target.wants/cliexec-cheat.service && echo YES || echo NO)"
echo "AUTOLOGINUSER=$(grep -o -- "--autologin [^ ]*" /etc/systemd/system/getty@tty1.service.d/90-autologin.conf 2>/dev/null | cut -d" " -f2)"
echo "BTMASK=$(readlink /etc/systemd/system/bluetooth.service 2>/dev/null || echo NOTMASKED)"
echo "SYSVINIT=$(test -x /lib/sysvinit/init && echo PRESENT || echo ABSENT)"
'
. "$(dirname "$0")/boot-lib.sh"

bt_build
bt_boot

echo "== results"
bt_check "the system booted at all" '===CLI-END==='
get() { sed -n "s/^$1=//p" "$SER.clean" | head -1; }
sed -n '/===CLI-MARKER===/,/===CLI-END===/p' "$SER.clean" | sed 's/^/   | /'

echo "-- it is the system the config asks for"
[ "$(get INIT)" = systemd ] && _p=1 || _p=0
[ "$_p" = 1 ] && bt_pass=$((bt_pass+1)) && echo "   PASS  PID 1 is systemd" \
              || { bt_bad=$((bt_bad+1)); echo "   FAIL  PID 1 is systemd (got '$(get INIT)')"; }
case "$(get OSID)" in
  debian-13*) bt_pass=$((bt_pass+1)); echo "   PASS  the base is Debian 13 trixie, not Devuan" ;;
  *)          bt_bad=$((bt_bad+1));  echo "   FAIL  the base is Debian 13 (got '$(get OSID)')" ;;
esac

echo "-- the handoff this branch rewrote"
bt_check     "the shutdown handler survived the pivot" '^SHUTDOWN=PRESENT$'
bt_check_not "and the old root is not empty"           '^INITRAMFSN=0$'
bt_check     "/run is a mountpoint, so systemd left it alone" '^RUNMOUNT=tmpfs$'
bt_check     "squashfs modules are mounted"            '^SQFS=[1-9]'
bt_check     "unioned with overlayfs"                  '^UNION=[1-9]'

echo "-- the cheatcodes, on the image we ship"
bt_check "cliexec runs from an enabled unit"  '^UNITENABLED=YES$'
bt_check "login= set the tty autologin user"  '^AUTOLOGINUSER=root$'
bt_check "nobluetooth masked bluetooth"       '^BTMASK=/dev/null$'

bt_finish

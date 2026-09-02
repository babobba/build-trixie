#!/bin/sh
# Boot test for the pxe cheatcode.
#
# A full end-to-end test would need a second VM on a shared virtual network to
# boot from the server this starts. What can be settled with one machine is the
# part most likely to be wrong and most likely to hurt: that asking for a PXE
# server on an image built without the daemons says so and leaves the machine
# alone, rather than half-starting a broken server or wedging the boot.
#
# That is not a small claim. The generated script runs from rc.local before the
# graphical session, so a script that hangs or writes /etc/exports on an image
# that cannot serve anything is a real regression, and the default config is the
# one almost everyone boots.
NAME=${NAME:-pxe}
CODES="${CODES:-pxe}"

# Run the generated script from the report rather than relying on the copy
# rc.local runs, so its output lands on the serial port in a known place.
REPORT='
echo "PXEFILE=$(test -x /usr/local/bin/pxe-server && echo EXECUTABLE || echo MISSING)"
echo "PXEROOT=$(sed -n "s/^PXEROOT=//p" /usr/local/bin/pxe-server 2>/dev/null)"
echo "---pxe-server output---"
/usr/local/bin/pxe-server 2>&1
echo "PXERC=$?"
echo "---end---"
# grep -c prints its count AND exits non-zero on no match, so "|| echo 0"
# would print the number twice and defeat an anchored pattern.
E=$(grep -c srv /etc/exports 2>/dev/null)
echo "EXPORTS=${E:-0}"
echo "DNSMASQCONF=$(test -e /etc/dnsmasq.d/pxe.conf && echo WRITTEN || echo ABSENT)"
'
. "$(dirname "$0")/boot-lib.sh"

bt_build
bt_boot

echo "== results"
bt_check "the system booted at all"                '===CLI-END==='
bt_check "the initrd said pxe would start later"   'pxe - PXE services will start'
bt_check "the server script was generated"         '^PXEFILE=EXECUTABLE$'

case "$CODES" in
  *nfspath=*)
	bt_check "nfspath= chose the export root" "^PXEROOT=$(
		echo "$CODES" | sed -n 's/.*nfspath=\([^ ]*\).*/\1/p')\$" ;;
  *)
	bt_check "the export root defaults to /srv/pxe" '^PXEROOT=/srv/pxe$' ;;
esac

# The live directory has to resolve before anything else is judged: if it does
# not, the script exits early and the checks below pass for the wrong reason.
bt_check_not "the live directory was found"        'cannot find the live directory'
bt_check "the missing packages are named"          'not starting, these are not installed:'
for p in dnsmasq nfs-kernel-server pxelinux; do
	bt_check "$p is named as missing"          "not installed:.*$p"
done
bt_check "the fix is spelled out"                  'build with configs-trixie/default-pxe.conf'
bt_check "it exits non-zero"                       '^PXERC=1$'

# Refusing to start has to mean refusing to change the machine.
bt_check "no export was added"                     '^EXPORTS=0$'
bt_check "no dnsmasq config was written"           '^DNSMASQCONF=ABSENT$'

# And the boot itself must be unharmed - this is the regression that would
# actually cost someone their afternoon.
[ -n "$BT_GUI" ] && bt_check "the desktop still came up" '===GUI-MARKER==='
bt_finish

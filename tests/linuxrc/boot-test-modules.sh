#!/bin/sh
# Do the extra squashfs modules on the medium load, and does what they carry
# work?
#
# The build can split packages out of the base squashfs into modules of their
# own (MODULE_PACKAGES in the config; Firefox by default), which linuxrc
# auto-loads from the live directory alongside 01-filesystem.squashfs. Every
# other boot test passes base_only so that a module can never hide a broken
# base; this one boots the full set and checks that the split package is
# there, runnable, and that the base really does not carry it.
NAME=${NAME:-modules}
BASE_ONLY=0
REPORT='
echo "SQFS=$(grep -c squashfs /proc/mounts)"
echo "MODULES=$(ls /mnt/live/memory/images/ 2>/dev/null | tr "\n" " ")"
echo "FIREFOX_BIN=$(test -x /usr/lib/firefox-esr/firefox-esr && echo PRESENT || echo MISSING)"
echo "FIREFOX_DESKTOP=$(test -f /usr/share/applications/firefox-esr.desktop && echo PRESENT || echo MISSING)"
echo "FIREFOX_VERSION=$(/usr/lib/firefox-esr/firefox-esr --version 2>/dev/null | head -1)"
echo "FIREFOX_IN_BASE=$(test -e /mnt/live/memory/images/01-filesystem.squashfs/usr/lib/firefox-esr && echo YES || echo NO)"
echo "FIREFOX_STATUSNEW=$(grep -c "^Package: firefox-esr" /var/lib/dpkg/statusnew 2>/dev/null)"
echo "FIREFOX_INFO=$(test -f /var/lib/dpkg/info/firefox-esr.list && echo PRESENT || echo MISSING)"
echo "WWW_BROWSER=$(readlink -f /etc/alternatives/x-www-browser 2>/dev/null)"
'
. "$(dirname "$0")/boot-lib.sh"

ls "$ISODATA"/live/*.squashfs | grep -qv -e 01-filesystem -e '/k-' || bt_skip "no extra module in $ISODATA/live - build with MODULE_PACKAGES set"

bt_build
bt_boot

echo "== results"
bt_check "the system booted at all" '===CLI-END==='
sed -n '/===CLI-MARKER===/,/===CLI-END===/p' "$SER.clean" | sed 's/^/   | /'
echo "-- the module is loaded"
bt_check "more than the base and kernel squashfs are mounted" '^SQFS=[3-9]'
# finit shortens mount names under /mnt/live/memory/images to nine
# characters plus a counter, so the module shows up as 05-firefo-2.squashfs.
bt_check "the firefox module is among the images"        '^MODULES=.*05-firefo'
echo "-- and what it carries works"
bt_check "the firefox binary is there"                   '^FIREFOX_BIN=PRESENT$'
bt_check "its menu entry is there"                       '^FIREFOX_DESKTOP=PRESENT$'
bt_check "and it runs"                                   '^FIREFOX_VERSION=Mozilla Firefox'
bt_check "x-www-browser resolves to it"                  '^WWW_BROWSER=.*firefox'
echo "-- the split is real"
bt_check "the base squashfs does not carry firefox"      '^FIREFOX_IN_BASE=NO$'
bt_check "dpkg's file list for it came with the module"  '^FIREFOX_INFO=PRESENT$'
bt_check "its status entry is carried as statusnew"      '^FIREFOX_STATUSNEW=1$'

bt_finish

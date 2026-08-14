#!/bin/sh
# The systemd-facing cheatcodes.
#
# Two groups. The service switches - nonetwork, nobluetooth, noupdateclock -
# used to chmod -x an init script, which on systemd changes nothing at all
# because unit files are not shell scripts. And three codes with no Porteus
# ancestor at all - default-target=, enable-services=, disable-services= -
# taken from MiniOS, which hit the same problem porting this lineage to a
# systemd Debian and answered it by adding codes that speak systemd.
#
# Everything is written offline, as symlinks and drop-ins under
# /etc/systemd/system. That directory outranks /lib and /usr/lib, which is what
# makes configuring a system whose init is not running possible at all: the
# symlinks here are exactly the ones systemctl enable and systemctl mask create.
#
# Masking rather than disabling is deliberate and is asserted as such. A
# disabled unit is still started when something else wants it, so a
# "disable-services" that only disabled would leave the service running - a
# cheatcode that reports success and does nothing.
. "$(dirname "$0")/lib.sh"

SD="$WORK/union/etc/systemd/system"

echo "-- masking is a symlink to /dev/null, the way systemctl mask writes it"
make_fakeroot; run_cheats "quiet from=/ nobluetooth"
assert_symlink "nobluetooth masks bluetooth" "$SD/bluetooth.service" /dev/null

echo "-- nonetwork takes down every network manager it can find"
make_fakeroot; run_cheats "quiet from=/ nonetwork"
for u in NetworkManager.service networking.service systemd-networkd.service \
         wpa_supplicant.service dhcpcd.service connman.service; do
	assert_symlink "$u is masked" "$SD/$u" /dev/null
done
# Masking NetworkManager alone would not be enough: it is Wants= of other
# units, so it would come back on demand. This is the check that the list is
# doing work rather than decorating.
assert_symlink "including the socket-activated one" "$SD/wpa_supplicant.service" /dev/null

echo "-- nothing is masked when nothing asks for it"
make_fakeroot; run_cheats "quiet from=/"
assert_no_file "bluetooth untouched"   "$SD/bluetooth.service"
assert_no_file "NetworkManager untouched" "$SD/NetworkManager.service"

echo "-- bluetooth turns it back on, and unmasks first"
make_fakeroot
ln -sf /dev/null "$SD/bluetooth.service"          # pretend a previous boot masked it
run_cheats "quiet from=/ bluetooth"
assert_symlink "it is enabled into multi-user" "$SD/multi-user.target.wants/bluetooth.service"
# Enabling without unmasking would leave a symlink to /dev/null winning, so the
# service would stay dead while the enable symlink claimed otherwise.
if [ -L "$SD/bluetooth.service" ] && [ "$(readlink "$SD/bluetooth.service")" = /dev/null ]; then
	_fail "the mask is lifted" "bluetooth.service is still masked"
else
	_pass "the mask is lifted"
fi

echo "-- default-target= repoints default.target"
make_fakeroot; run_cheats "quiet from=/ default-target=multi-user.target"
assert_symlink "default.target follows the cheatcode" "$SD/default.target" multi-user.target

echo "-- and accepts a bare name, since that is what people type"
make_fakeroot; run_cheats "quiet from=/ default-target=rescue"
assert_symlink "rescue becomes rescue.target" "$SD/default.target" rescue.target

echo "-- a target that is not installed is refused, not linked to nothing"
make_fakeroot; run_cheats "quiet from=/ default-target=nonexistent.target"
assert_no_file "no dangling default.target" "$SD/default.target"
assert_grep "and the user is told"          "$WORK/output" 'is not installed'

echo "-- enable-services= takes a list"
make_fakeroot; run_cheats "quiet from=/ enable-services=ssh,cups"
assert_symlink "ssh is enabled"  "$SD/multi-user.target.wants/ssh.service"
assert_symlink "cups is enabled" "$SD/multi-user.target.wants/cups.service"

echo "-- disable-services= masks rather than merely disabling"
make_fakeroot; run_cheats "quiet from=/ disable-services=cups"
assert_symlink "cups is masked" "$SD/cups.service" /dev/null

echo "-- an unknown service is reported instead of silently enabling nothing"
make_fakeroot; run_cheats "quiet from=/ enable-services=notinstalled"
assert_no_file "nothing is linked"  "$SD/multi-user.target.wants/notinstalled.service"
assert_grep "and the user is told"  "$WORK/output" 'is not installed'

echo "-- the enable symlink points at the real unit file"
# A .wants entry pointing at a path that does not exist is the same as no entry,
# and is the failure mode of writing the symlink by hand.
make_fakeroot; run_cheats "quiet from=/ enable-services=ssh"
TGT=$(readlink "$SD/multi-user.target.wants/ssh.service" 2>/dev/null)
assert_equal "it resolves to the shipped unit" "/lib/systemd/system/ssh.service" "$TGT"

echo "-- a union with no systemd is called out"
# The symlinks are still written - they are inert on a system with no systemd,
# and would take effect if one were added later. What must not happen is
# silence: an initrd that targets systemd, handed a union without it, has to
# say so rather than let the boot look configured.
make_fakeroot; unmake_fake_systemd
run_cheats "quiet from=/ nobluetooth"
assert_grep "the absence is reported" "$WORK/output" 'no systemd in the union'

finish

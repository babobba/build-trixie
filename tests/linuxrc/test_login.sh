#!/bin/sh
# login= / nologin : the tty1 autologin, now a getty@tty1 drop-in.
#
# It used to be a line in /etc/inittab. On systemd there is no inittab, and the
# supported way to change a packaged unit's command is a drop-in under
# /etc/systemd/system/<unit>.d/ - so that is what these assert on.
. "$(dirname "$0")/lib.sh"

make_fakeroot; run_cheats "quiet login=puppy"
assert_file "login= writes a getty drop-in"    "$WORK/union/etc/systemd/system/getty@tty1.service.d/90-autologin.conf"
assert_grep "it autologs in the named user"   "$WORK/union/etc/systemd/system/getty@tty1.service.d/90-autologin.conf" '--autologin puppy'
assert_not_grep "and not the previous user"    "$WORK/union/etc/systemd/system/getty@tty1.service.d/90-autologin.conf" '--autologin root'
# Without the empty ExecStart= first, systemd appends to the packaged command
# instead of replacing it and the unit refuses to start.
assert_grep "ExecStart is cleared before being set" "$WORK/union/etc/systemd/system/getty@tty1.service.d/90-autologin.conf" '^ExecStart=$'

make_fakeroot; run_cheats "quiet nologin"
# The image ships its own getty@tty1.service that autologs in as root, so
# simply removing our drop-in would hand the autologin back rather than take it
# away. nologin has to override whatever is underneath.
assert_file "nologin still writes a drop-in"  "$WORK/union/etc/systemd/system/getty@tty1.service.d/90-autologin.conf"
assert_not_grep "with no autologin in it"     "$WORK/union/etc/systemd/system/getty@tty1.service.d/90-autologin.conf" '--autologin'
assert_grep "and a plain getty instead"       "$WORK/union/etc/systemd/system/getty@tty1.service.d/90-autologin.conf" 'agetty --noclear %I'


# With a display manager installed, build-trixie has already swapped in
# a display manager, so the tty drop-in alone decides nothing -- the display manager has
# to be configured too.
with_dm() {   # $1 = display manager binary path, $2.. = extra setup
	make_fakeroot
	mkdir -p "$WORK/union/etc/X11"
	echo "$1" > "$WORK/union/etc/X11/default-display-manager"
}

echo "-- slim (the display manager this repo pins)"
with_dm /usr/bin/slim
printf '# default_user  simone\n# auto_login   no\n' > "$WORK/union/etc/slim.conf"
run_cheats "quiet login=puppy"
assert_grep "slim gets the autologin user"  "$WORK/union/etc/slim.conf" '^default_user *puppy'
assert_grep "slim autologin is enabled"     "$WORK/union/etc/slim.conf" '^auto_login *yes'

with_dm /usr/bin/slim
printf 'default_user        puppy\nauto_login          yes\n' > "$WORK/union/etc/slim.conf"
run_cheats "quiet nologin"
assert_grep "nologin turns slim autologin off" "$WORK/union/etc/slim.conf" '^auto_login *no'

echo "-- slim.conf without the keys at all"
with_dm /usr/bin/slim; : > "$WORK/union/etc/slim.conf"
run_cheats "quiet login=puppy"
assert_grep "the user key is appended"      "$WORK/union/etc/slim.conf" '^default_user *puppy'
assert_grep "the autologin key is appended" "$WORK/union/etc/slim.conf" '^auto_login *yes'

echo "-- lightdm, sddm and gdm3 use drop-ins where they can"
with_dm /usr/sbin/lightdm; run_cheats "quiet login=puppy"
assert_grep "lightdm drop-in names the user" "$WORK/union/etc/lightdm/lightdm.conf.d/90-autologin.conf" '^autologin-user=puppy'
assert_grep "lightdm drop-in has a seat"     "$WORK/union/etc/lightdm/lightdm.conf.d/90-autologin.conf" '^\[Seat:\*\]'
with_dm /usr/sbin/lightdm; run_cheats "quiet nologin"
assert_grep "nologin empties the lightdm user" "$WORK/union/etc/lightdm/lightdm.conf.d/90-autologin.conf" '^autologin-user=$'

with_dm /usr/bin/sddm; run_cheats "quiet login=puppy"
assert_grep "sddm drop-in names the user"    "$WORK/union/etc/sddm.conf.d/90-autologin.conf" '^User=puppy'
with_dm /usr/bin/sddm; run_cheats "quiet nologin"
assert_grep "nologin empties the sddm user"  "$WORK/union/etc/sddm.conf.d/90-autologin.conf" '^User=$'

with_dm /usr/sbin/gdm3; run_cheats "quiet login=puppy"
assert_grep "gdm3 autologin is enabled"      "$WORK/union/etc/gdm3/daemon.conf" '^AutomaticLoginEnable=true'
assert_grep "gdm3 names the user"            "$WORK/union/etc/gdm3/daemon.conf" '^AutomaticLogin=puppy'
with_dm /usr/sbin/gdm3; run_cheats "quiet nologin"
assert_grep "nologin disables gdm3 autologin" "$WORK/union/etc/gdm3/daemon.conf" '^AutomaticLoginEnable=false'

echo "-- an unknown display manager says so instead of failing silently"
with_dm /usr/bin/entrance; run_cheats "quiet login=puppy"
assert_grep "the user is warned"             "$WORK/output" 'display manager entrance is not known'
assert_grep "the tty autologin is still set" "$WORK/union/etc/systemd/system/getty@tty1.service.d/90-autologin.conf" '--autologin puppy'

echo "-- no display manager: nothing extra is written"
make_fakeroot; run_cheats "quiet login=puppy"
assert_no_file "no lightdm drop-in appears"  "$WORK/union/etc/lightdm/lightdm.conf.d/90-autologin.conf"
assert_no_file "no sddm drop-in appears"     "$WORK/union/etc/sddm.conf.d/90-autologin.conf"
assert_no_file "no gdm3 config appears"      "$WORK/union/etc/gdm3/daemon.conf"
assert_not_grep "no warning is printed"      "$WORK/output" 'not known here'

finish

#!/bin/sh
# login= / nologin : the tty1 autologin line in /etc/inittab
. "$(dirname "$0")/lib.sh"

make_fakeroot; run_cheats "quiet login=puppy"
assert_grep "login= sets the autologin user"   "$WORK/union/etc/inittab" 'login -f puppy'
assert_not_grep "root autologin is replaced"   "$WORK/union/etc/inittab" 'login -f root'
assert_grep "other inittab lines survive"      "$WORK/union/etc/inittab" 'getty 38400 tty2'

make_fakeroot; run_cheats "quiet nologin"
assert_grep "nologin puts getty on tty1"       "$WORK/union/etc/inittab" '^1:2345:respawn:/sbin/getty 38400 tty1'
assert_not_grep "nologin removes autologin"    "$WORK/union/etc/inittab" 'login -f'

finish

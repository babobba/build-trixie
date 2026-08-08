#!/bin/sh
# kmap= : keyboard layout, written to /etc/default/keyboard
. "$(dirname "$0")/lib.sh"

make_fakeroot; run_cheats "quiet kmap=fr"
assert_grep "kmap= sets XKBLAYOUT"            "$WORK/union/etc/default/keyboard" 'XKBLAYOUT="fr"'
assert_not_grep "old layout is replaced"      "$WORK/union/etc/default/keyboard" 'XKBLAYOUT="us"'
assert_grep "XKBMODEL is left alone"          "$WORK/union/etc/default/keyboard" 'XKBMODEL="pc105"'
assert_grep "XKBVARIANT is left alone"        "$WORK/union/etc/default/keyboard" 'XKBVARIANT=""'

# A layout with a variant suffix must survive verbatim.
make_fakeroot; run_cheats "quiet kmap=gb"
assert_grep "two-letter layouts work"         "$WORK/union/etc/default/keyboard" 'XKBLAYOUT="gb"'

# Missing keyboard file: the code should create one rather than fail.
make_fakeroot; rm -f "$WORK/union/etc/default/keyboard"; run_cheats "quiet kmap=de"
assert_grep "keyboard file is created if absent" "$WORK/union/etc/default/keyboard" 'XKBLAYOUT="de"'

finish

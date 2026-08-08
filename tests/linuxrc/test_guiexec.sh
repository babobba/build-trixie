#!/bin/sh
# guiexec= : commands started with the desktop session
. "$(dirname "$0")/lib.sh"

make_fakeroot; run_cheats "quiet guiexec=xterm~-T~hi;leafpad"
ROOTAS="$WORK/union/root/.config/openbox/autostart"
PUPAS="$WORK/union/home/puppy/.config/openbox/autostart"
assert_grep "guiexec= reaches root's session"  "$ROOTAS" 'xterm -T hi &'
assert_grep "guiexec= reaches puppy's session" "$PUPAS"  'xterm -T hi &'
assert_grep "guiexec= splits commands on ;"    "$ROOTAS" 'leafpad &'
assert_grep "commands are backgrounded"        "$PUPAS"  'leafpad &'

finish

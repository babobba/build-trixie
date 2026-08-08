#!/bin/sh
# guiexec= : commands started with the desktop session.
#
# The entry point is an XDG autostart .desktop file, which every desktop this
# repo can build honours (Openbox/LXDE, Xfce, Mate, LXQt), rather than one
# window manager's own config.
. "$(dirname "$0")/lib.sh"

DESKTOP="$WORK/union/etc/xdg/autostart/guiexec-cheat.desktop"
SCRIPT="$WORK/union/usr/local/bin/guiexec-cheat"

make_fakeroot; run_cheats "quiet guiexec=xterm~-T~hi;leafpad"
assert_file "an autostart .desktop is written"   "$DESKTOP"
assert_grep "it is an Application entry"         "$DESKTOP" '^Type=Application'
assert_grep "it runs the generated script"       "$DESKTOP" '^Exec=/usr/local/bin/guiexec-cheat$'
assert_grep "it is hidden from menus"            "$DESKTOP" '^NoDisplay=true'
assert_file "the script is written"              "$SCRIPT"
assert_executable "the script is executable"     "$SCRIPT"
assert_grep "it starts with a shebang"           "$SCRIPT" '^#!/bin/sh'
assert_grep "~ becomes a space"                  "$SCRIPT" '^xterm -T hi &'
assert_grep "; separates commands"               "$SCRIPT" '^leafpad &'
assert_grep "the script exits cleanly"           "$SCRIPT" '^exit 0'

echo "-- Openbox is covered too (openbox-xdg-autostart needs PyXDG, which is absent)"
assert_grep "root's session calls the script" \
	"$WORK/union/root/.config/openbox/autostart" '^/usr/local/bin/guiexec-cheat &'
assert_grep "puppy's session calls the script" \
	"$WORK/union/home/puppy/.config/openbox/autostart" '^/usr/local/bin/guiexec-cheat &'
assert_not_grep "the commands are not duplicated into openbox" \
	"$WORK/union/root/.config/openbox/autostart" 'xterm'

echo "-- running it twice only starts the commands once"
assert_grep "the script takes a lock"      "$SCRIPT" 'mkdir /tmp/.guiexec-cheat-'
assert_grep "the lock is boot-scoped"      "$SCRIPT" 'boot_id'
assert_grep "a second run exits early"     "$SCRIPT" '|| exit 0'
# Prove it: run the generated script twice with the commands stubbed.
sed -e 's#^xterm -T hi &#echo RAN >> '"$WORK"'/ran#' -e 's#^leafpad &##' "$SCRIPT" > "$WORK/gx.sh"
rm -f "$WORK/ran"; sh "$WORK/gx.sh"; sh "$WORK/gx.sh"
assert_equal "commands ran exactly once" "1" "$(grep -c RAN "$WORK/ran" 2>/dev/null || echo 0)"

echo "-- it works on a build with no Openbox at all (Xfce, Mate, LXQt)"
make_fakeroot
rm -rf "$WORK/union/root/.config/openbox" "$WORK/union/home/puppy/.config/openbox"
run_cheats "quiet guiexec=thunar"
assert_file "the .desktop is still written"      "$DESKTOP"
assert_grep "the command is still registered"    "$SCRIPT" '^thunar &'

echo "-- nothing is written without the cheatcode"
make_fakeroot; run_cheats "quiet"
assert_no_file "no .desktop is left behind"      "$DESKTOP"
assert_no_file "no script is left behind"        "$SCRIPT"
assert_not_grep "openbox autostart is untouched" \
	"$WORK/union/root/.config/openbox/autostart" 'guiexec' 

finish

#!/bin/sh
# Do the X programs the config installs open a window?
#
# The static checks read files and boot-test-programs.sh starts programs on
# a console; neither can tell whether a GTK program gets as far as a window,
# which is where a missing theme engine, a broken icon cache or a library
# that loads but cannot initialise shows up. This one boots the image with
# its desktop, and at the guiexec stage starts every program that the
# config's packages register in a .desktop file - plus the dog tools built
# on yad or gtkdialog - and waits for a new window. The guest side is
# guest-probe-gui; the report format is described at the top of that file.
# When a program produces no window the host takes a screenshot through the
# QEMU monitor (fail-NAME.png in the work directory) while the screen still
# shows it.
#
# Slow - most GTK programs need ten to thirty seconds each under emulation,
# Firefox two minutes - and sensitive to timing, so this runs on its own and
# is not part of boot-test-all.sh. Run it before a release. Modules on the
# medium are loaded (BASE_ONLY=0) so that Firefox, shipped as one, is
# covered.
NAME=${NAME:-gui}
BASE_ONLY=${BASE_ONLY:-0}
CLI_TIMEOUT=${CLI_TIMEOUT:-400}
GUI_TIMEOUT=${GUI_TIMEOUT:-2700}
CODES="${CODES:-login=root disable-services=cups nobluetooth}"
. "$(dirname "$0")/boot-lib.sh"
# the branch's default config: the systemd one where it exists, else default.conf
[ -f "$REPO/configs-trixie/default-systemd.conf" ] && _dc=default-systemd.conf || _dc=default.conf
CONFIG=${CONFIG:-$REPO/configs-trixie/$_dc}
PKGS=$(bt_config_packages "$CONFIG" | tr '\n' ' ')
REPORT='echo "DESKTOP=$(ps -eo comm= | grep -m1 -E "^(openbox|jwm|xfwm4|openbox-session|icewm)")"'

bt_extra_setup() {
	cp "$BT_DIR/guest-probe-gui" "$WORK/iso/live/rootcopy/usr/local/bin/probe-gui"
	printf '#!/bin/sh\nPKGS=%s BUDGET=%s exec /usr/local/bin/probe-gui\n' "'$PKGS'" "${BUDGET:-60}" \
		> "$WORK/iso/live/rootcopy/usr/local/bin/rgui"
	chmod +x "$WORK/iso/live/rootcopy/usr/local/bin/probe-gui" "$WORK/iso/live/rootcopy/usr/local/bin/rgui"
	find "$WORK/iso/live/rootcopy" -type d -exec touch -d 2000-01-01 {} +
}

# Screenshot each failure as it is reported, while the guest still shows it.
bt_poll() {
	grep -a '^GUI-FAIL ' "$SER" 2>/dev/null | tr -d '\r' | while read -r _ name; do
		[ -e "$WORK/fail-$name.ppm" ] || [ -e "$WORK/fail-$name.png" ] && continue
		bt_screendump "$WORK/fail-$name.ppm"
		echo "   screenshot of $name's failure: $WORK/fail-$name.*"
	done
}

echo "== $(echo $PKGS | wc -w) packages from ${CONFIG#$REPO/}"
bt_build
bt_boot

echo "== results"
grep -E '^GUI ' "$SER.clean" | sed 's/^/   | /'
bt_check "the probe ran in a display"         '^GUI [^ ]* '
bt_check_not "the session had a display"      '^GUI-NODISPLAY'
bt_check_not "xdotool is on the image"        '^GUI-NOXDOTOOL'
bt_check "the probe ran to the end"           '^GUI-DONE [1-9]'
echo "   $(grep -c '^GUI [^ ]* OK' "$SER.clean") opened a window, $(grep -c '^GUI [^ ]* NOWINDOW' "$SER.clean") did not, $(grep -c '^GUI [^ ]* SKIP' "$SER.clean") skipped"
bt_check "at least five programs opened a window" '^GUI-DONE \([5-9]\|[1-9][0-9]\)'
bt_check "pcmanfm opened a window"            '^GUI pcmanfm OK'
bt_check_not "every program opened a window"  '^GUI [^ ]* NOWINDOW'
bt_check_not "no program failed to load"      '^GUI [^ ]* NOWINDOW.*\(error while loading\|cannot open shared\|not found\)'

bt_finish

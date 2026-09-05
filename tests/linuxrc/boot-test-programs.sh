#!/bin/sh
# Can the programs the config installs actually start?
#
# tests/image/test_executables.sh reads the image and checks what every file
# says it needs. This boots it and runs them: every program the config's
# packages put in /usr/bin and /usr/sbin is started with --version at the
# cliexec stage, and a set of terminal programs is given a pseudo-terminal
# and five seconds. The guest side is guest-probe-programs, delivered
# through rootcopy; the report format is described at the top of that file.
#
# The list of packages comes from the config (CONFIG=..., default
# configs-trixie/default-systemd.conf), so a package that is named there and
# not on the medium is a failure here, not a skip. Under emulation about a
# hundred and fifty programs take five to ten minutes; the cliexec budget is
# set accordingly.
NAME=${NAME:-programs}
CLI_TIMEOUT=${CLI_TIMEOUT:-1500}
GUI_TIMEOUT=${GUI_TIMEOUT:-1800}
CODES="${CODES:-login=root disable-services=cups nobluetooth}"
. "$(dirname "$0")/boot-lib.sh"
# the branch's default config: the systemd one where it exists, else default.conf
[ -f "$REPO/configs-trixie/default-systemd.conf" ] && _dc=default-systemd.conf || _dc=default.conf
CONFIG=${CONFIG:-$REPO/configs-trixie/$_dc}
PKGS=$(bt_config_packages "$CONFIG" | tr '\n' ' ')
REPORT="PKGS='$PKGS' /usr/local/bin/probe-programs"

bt_extra_setup() {
	cp "$BT_DIR/guest-probe-programs" "$WORK/iso/live/rootcopy/usr/local/bin/probe-programs"
	chmod +x "$WORK/iso/live/rootcopy/usr/local/bin/probe-programs"
	find "$WORK/iso/live/rootcopy" -type d -exec touch -d 2000-01-01 {} +
}

echo "== $(echo $PKGS | wc -w) packages from ${CONFIG#$REPO/}"
bt_build
bt_boot

echo "== results"
bt_check "the probe ran to the end" '^PROBED [0-9]'
grep -a -E '^(PROBE [^ ]+ (FAIL|RUNNING)|TUI [^ ]+ FAIL|PKG-MISSING)' "$SER.clean" | sed 's/^/   | /'
echo "   probed: $(sed -n 's/^PROBED //p' "$SER.clean" | head -1) programs, $(grep -a -c '^PROBE [^ ]* OK' "$SER.clean") ok, $(grep -a -c '^PROBE [^ ]* SKIP' "$SER.clean") on the denylist; TUI: $(grep -a -c '^TUI [^ ]* OK' "$SER.clean") ok, $(grep -a -c '^TUI [^ ]* SKIP' "$SER.clean") absent"

echo "-- packages and programs"
bt_check_not "every package the config names is installed" '^PKG-MISSING '
bt_check     "the list is not trivially short"    '^PROBED \([6-9][0-9]\|[1-9][0-9][0-9]\)'

echo "-- command-line programs"
bt_check_not "no program failed to start"          '^PROBE [^ ]* FAIL'

echo "-- terminal programs"
bt_check     "at least one terminal program drew its screen" '^TUI [^ ]* OK'
bt_check_not "no terminal program failed"          '^TUI [^ ]* FAIL'

bt_finish

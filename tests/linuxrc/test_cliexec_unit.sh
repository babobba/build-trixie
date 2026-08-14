#!/bin/sh
# volume= / zram= / cliexec= : commands that must have run before X starts.
#
# They are collected into /usr/local/bin/cliexec-cheat, started by a systemd
# unit ordered before the display manager. That ordering is the entire content
# of the cheatcode: Porteus documents cliexec= as "runlevel 3", i.e. before X.
#
# It used to be wired through /etc/rc.local and a sed into /etc/profile, racing
# each other under a boot-scoped lock, because sysvinit gave no way to say
# "before X" outright. A unit does, so those hooks are gone and these tests
# assert on the unit instead.
. "$(dirname "$0")/lib.sh"

UNIT="$WORK/union/etc/systemd/system/cliexec-cheat.service"
WANTS="$WORK/union/etc/systemd/system/multi-user.target.wants/cliexec-cheat.service"
CX="$WORK/union/usr/local/bin/cliexec-cheat"
PROFILE="$WORK/union/etc/profile"

make_fakeroot; run_cheats "quiet volume=42% zram=25 cliexec=echo~hello~world;touch~/tmp/flag"

echo "-- the commands live in one script"
assert_file "the script is written"              "$CX"
assert_executable "the script is executable"     "$CX"
assert_grep "volume= writes an amixer call"      "$CX" 'amixer -q set Master 42%'
assert_grep "zram= sets the disk size"           "$CX" 'zram0/disksize'
assert_grep "zram= honours the percentage"       "$CX" '\* 25 / 100'
assert_grep "zram= swaps the device on"          "$CX" 'swapon -p 100 /dev/zram0'
assert_grep "cliexec= turns ~ into spaces"       "$CX" 'echo hello world'
assert_grep "cliexec= splits commands on ;"      "$CX" 'touch /tmp/flag'
assert_grep "it takes a boot-scoped lock"        "$CX" 'mkdir /tmp/.cliexec-cheat-'
assert_grep "the lock is keyed to the boot"      "$CX" 'boot_id'

echo "-- started by a unit, not by rc.local"
assert_file "the unit is written"                "$UNIT"
assert_grep "it runs the script"                 "$UNIT" '^ExecStart=/usr/local/bin/cliexec-cheat$'
assert_grep "it is a oneshot"                    "$UNIT" '^Type=oneshot$'

echo "-- ordered before the graphical session, which is the whole point"
assert_grep "before the display manager"         "$UNIT" '^Before=.*display-manager.service'
assert_grep "and before graphical.target"        "$UNIT" '^Before=.*graphical.target'

echo "-- and actually enabled, not merely written"
# A unit file nothing links to never runs. This is the symlink systemctl enable
# would have made.
assert_symlink "enabled into multi-user.target"  "$WANTS"

echo "-- a failing cheatcode does not stop the boot"
assert_grep "a non-zero exit is tolerated"       "$UNIT" '^SuccessExitStatus='

echo "-- the sysvinit hooks are gone"
# rc.local exists in the image already; what matters is that nothing was added
# to it, since on systemd nothing dependable would read it.
assert_not_grep "rc.local is left alone"         "$WORK/union/etc/rc.local" 'cliexec-cheat'
assert_grep "profile still calls startx plainly" "$WORK/union/etc/profile" '^startx$'

echo "-- with no cheatcodes given, nothing is written at all"
make_fakeroot; run_cheats "quiet from=/"
assert_no_file "no script"                       "$CX"
assert_no_file "no unit"                         "$UNIT"
assert_no_file "no enable symlink"               "$WANTS"
assert_grep "profile is left alone"              "$WORK/union/etc/profile" '^startx$'

finish

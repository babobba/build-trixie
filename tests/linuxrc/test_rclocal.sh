#!/bin/sh
# volume= / zram= / cliexec= : commands that must have run before X starts.
#
# They are collected into /usr/local/bin/cliexec-cheat, which is called both
# from /etc/rc.local and from /etc/profile just before startx, under a
# boot-scoped lock so it still runs once.
. "$(dirname "$0")/lib.sh"

RCL="$WORK/union/etc/rc.local"
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

echo "-- called from rc.local"
assert_grep "rc.local calls the script"          "$RCL" '^/usr/local/bin/cliexec-cheat'
assert_grep "the original rc.local body stays"   "$RCL" 'cowsave'
assert_executable "rc.local stays executable"    "$RCL"
assert_equal "rc.local keeps one exit 0" "1"     "$(grep -c '^exit 0' "$RCL")"
assert_equal "exit 0 is the last line"   "exit 0" "$(tail -n1 "$RCL")"
assert_not_grep "commands are not inlined there" "$RCL" 'amixer'

echo "-- and from /etc/profile, so it cannot lose the race with startx"
assert_grep "profile calls it before startx"     "$PROFILE" '^/usr/local/bin/cliexec-cheat; startx$'
assert_not_grep "no bare startx line is left"    "$PROFILE" '^startx$'
assert_grep "the tty1 guard is untouched"        "$PROFILE" 'tty) = /dev/tty1'

echo "-- but the commands still only run once"
# Stub the real commands, then run the generated script twice.
sed -e "s#^amixer .*#echo RAN >> $WORK/ran#" -e '/^echo hello/d' -e '/^touch /d' \
    -e '/^modprobe zram/d' -e '/^if \[ -e \/sys\/block\/zram0/,/^fi$/d' "$CX" > "$WORK/cx.sh"
rm -rf /tmp/.cliexec-cheat-*; rm -f "$WORK/ran"
sh "$WORK/cx.sh"; sh "$WORK/cx.sh"
assert_equal "commands ran exactly once" "1" "$(grep -c RAN "$WORK/ran" 2>/dev/null || echo 0)"

echo "-- a percent sign is optional on volume="
make_fakeroot; run_cheats "quiet volume=80"
assert_grep "volume= works without a % sign"     "$CX" 'Master 80%'

echo "-- rc.local is created when the image has none"
make_fakeroot; rm -f "$RCL"; run_cheats "quiet volume=10"
assert_file "rc.local is created"                "$RCL"
assert_grep "it has a shebang"                   "$RCL" '^#!/bin/sh'
assert_equal "it ends with exit 0" "exit 0"      "$(tail -n1 "$RCL")"

echo "-- nothing is written without any of these cheatcodes"
make_fakeroot; run_cheats "quiet from=/ base_only"
assert_no_file "no script is left behind"        "$CX"
assert_grep "profile still calls startx plainly" "$PROFILE" '^startx$'
assert_not_grep "rc.local is untouched"          "$RCL" 'cliexec-cheat'

finish

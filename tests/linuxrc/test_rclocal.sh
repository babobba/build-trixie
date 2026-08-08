#!/bin/sh
# volume= / zram= / cliexec= all land in /etc/rc.local
. "$(dirname "$0")/lib.sh"

make_fakeroot; run_cheats "quiet volume=42% zram=25 cliexec=echo~hello~world;touch~/tmp/flag"
RCL="$WORK/union/etc/rc.local"
assert_grep "volume= writes an amixer call"    "$RCL" 'amixer -q set Master 42%'
assert_grep "zram= sets the disk size"         "$RCL" 'zram0/disksize'
assert_grep "zram= honours the percentage"     "$RCL" '\* 25 / 100'
assert_grep "zram= swaps the device on"        "$RCL" 'swapon -p 100 /dev/zram0'
assert_grep "cliexec= turns ~ into spaces"     "$RCL" 'echo hello world'
assert_grep "cliexec= splits commands on ;"    "$RCL" 'touch /tmp/flag'
assert_grep "the original rc.local body stays" "$RCL" 'cowsave'
assert_executable "rc.local stays executable"  "$RCL"
assert_equal "rc.local keeps one exit 0" "1" "$(grep -c '^exit 0' "$RCL")"
assert_equal "exit 0 is the last line"   "exit 0" "$(tail -n1 "$RCL")"

# A percent sign is optional on volume=.
make_fakeroot; run_cheats "quiet volume=80"
assert_grep "volume= works without a % sign"   "$WORK/union/etc/rc.local" 'Master 80%'

# rc.local should be created from scratch when the image has none.
make_fakeroot; rm -f "$WORK/union/etc/rc.local"; run_cheats "quiet volume=10"
assert_file "rc.local is created if absent"    "$WORK/union/etc/rc.local"
assert_grep "created rc.local has a shebang"   "$WORK/union/etc/rc.local" '^#!/bin/sh'
assert_equal "created rc.local ends with exit 0" "exit 0" "$(tail -n1 "$WORK/union/etc/rc.local")"

finish

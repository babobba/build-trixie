#!/bin/sh
# With no cheatcodes, the image must come out untouched.  This is the
# regression guard for the whole block.
. "$(dirname "$0")/lib.sh"

make_fakeroot
for f in etc/rc.local etc/inittab etc/default/keyboard \
         root/.config/openbox/autostart home/puppy/.config/openbox/autostart; do
	mkdir -p "$WORK/before/$(dirname "$f")"
	cp -a "$WORK/union/$f" "$WORK/before/$f"
done

run_cheats "quiet from=/ base_only norootcopy copy2ram changes=/live/changes.dat"

for f in etc/rc.local etc/inittab etc/default/keyboard \
         root/.config/openbox/autostart home/puppy/.config/openbox/autostart; do
	assert_same_file "$f is untouched" "$WORK/before/$f" "$WORK/union/$f"
done
assert_no_file "no /etc/timezone is invented"  "$WORK/union/etc/timezone"
assert_no_file "no /etc/adjtime is invented"   "$WORK/union/etc/adjtime"
assert_executable "hwclock.sh still enabled"   "$WORK/union/etc/init.d/hwclock.sh"
assert_executable "bluetooth still enabled"    "$WORK/union/etc/init.d/bluetooth"

finish

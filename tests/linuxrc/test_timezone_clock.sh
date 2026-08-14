#!/bin/sh
# timezone= / utc / noupdateclock
. "$(dirname "$0")/lib.sh"

make_fakeroot; run_cheats "quiet timezone=Europe/Amsterdam utc"
assert_grep "timezone= writes /etc/timezone"   "$WORK/union/etc/timezone" '^Europe/Amsterdam$'
assert_symlink "timezone= relinks /etc/localtime" "$WORK/union/etc/localtime" 'Europe/Amsterdam'
assert_grep "utc writes UTC to /etc/adjtime"   "$WORK/union/etc/adjtime" '^UTC$'

# An unknown zone must be refused, not written blindly.
make_fakeroot; run_cheats "quiet timezone=Mars/Olympus"
assert_no_file "unknown timezone is ignored"   "$WORK/union/etc/timezone"
assert_symlink "localtime is left at its default" "$WORK/union/etc/localtime" 'Etc/UTC'

# Without utc, no adjtime should appear (the system keeps its default).
make_fakeroot; run_cheats "quiet timezone=Europe/Amsterdam"
assert_no_file "adjtime not written without utc" "$WORK/union/etc/adjtime"

make_fakeroot; run_cheats "quiet noupdateclock"
# systemd has no hwclock.sh. The RTC is written by timesyncd on a good sync, so
# masking that unit is the equivalent - and masking, not disabling, because a
# disabled unit can still be pulled in as another unit's dependency.
assert_symlink "noupdateclock masks timesyncd" \
	"$WORK/union/etc/systemd/system/systemd-timesyncd.service" /dev/null

make_fakeroot; run_cheats "quiet"
assert_no_file "timesyncd untouched by default" \
	"$WORK/union/etc/systemd/system/systemd-timesyncd.service"

finish

#!/bin/sh
# The initrd is not a Debian userland.
#
# linuxrc and finit run inside initrd1.xz, where the only binaries are a
# busybox 1.31.1 built with a reduced applet set plus a few tools mkinitrd
# copies in.  Anything outside that set fails with "not found", and because so
# much of linuxrc runs inside command substitution with stderr discarded, the
# failure is silent: the variable comes back empty and the boot carries on.
# That is how the forensic cheatcode came to skip every partition on a
# partitioned disk -- `basename \`dirname $PD\`` produced nothing -- while the
# boot test still reported success.
#
# The other unit tests cannot catch this. They run the extracted regions under
# the host's /bin/sh, where dirname, head, expr and awk all exist. So this one
# checks the source text instead.
#
# The inventory below is the actual content of bin, sbin, usr/bin and usr/sbin
# in an unpacked initrd1.xz, and can be regenerated with:
#
#     xz -dc trixie/isodata/live/initrd1.xz | cpio -idm
#     ls bin sbin usr/bin usr/sbin | sort -u
#
# printf and let are not applets but are ash builtins, so they are fine; both
# were checked against the initrd's own busybox rather than assumed.
. "$(dirname "$0")/lib.sh"

APPLETS="ash basename bash blkid blockdev bootchartd busybox cat chmod chown
chroot clear cp cryptsetup cttyhack cut date df dmesg e2fsck echo egrep eject
fb find free grep halt ifconfig kill killall link ln losetup ls lsmod lsof
lspci md5sum mkdir mknod modinfo modprobe mount mv ntfs-3g ping pivot_root
poweroff ps readahead reboot reiserfsck rev rm rmdir route sed setsid sh sleep
sort switch_root sync tac tail tar tee touch tr udhcpc umount uname uniq unlink
usleep vi"

# Commands a shell script on Debian would normally be free to use.  Whatever
# is in this list but not in APPLETS is what the initrd cannot run.  Rather
# than parse shell -- which produced more false positives than findings -- the
# test looks only for these, which is the failure mode that actually happens:
# reaching for a familiar tool that busybox was not built with.
COMMON="awk gawk mawk dirname head expr seq stat wc xargs realpath readlink
env truncate mktemp nl paste comm join split fold fmt pr od hexdump xxd base64
sha1sum sha256sum cksum shuf timeout nohup nice ionice flock getopt column
pgrep pkill lsblk findmnt mountpoint partprobe sfdisk fdisk parted hdparm
rsync curl wget python python3 perl file id whoami groups pidof strings
install chgrp du dd stdbuf watch tput less more diff cmp patch"

missing_commands() {
	for c in $COMMON; do
		found=0
		for a in $APPLETS; do [ "$c" = "$a" ] && { found=1; break; }; done
		[ "$found" = 0 ] && echo "$c"
	done
}

# Strip the parts of the script that are *written* rather than *run*: heredoc
# bodies, lines appended to a generated script, and anything landing under
# /union.  Those become files in the booted Debian system, where the full
# userland is available -- the zram= snippet's use of awk is correct because it
# runs from /etc/rc.local, not from the initrd.
strip_generated() {   # FILE
	sed -e '/<<[-]*['"'"'"]*[A-Za-z_][A-Za-z0-9_]*['"'"'"]*[[:space:]]*$/,/^[A-Z_][A-Z0-9_]*[[:space:]]*$/d' \
	    -e '/\$CHEATRC/d' -e '/\$GUIRC/d' -e '/\$RCL/d' \
	    -e '/\/union\//d' \
	    -e 's/#.*//' "$1"
}

# Match only in command position: start of line, or after a pipe, backtick,
# "$(", semicolon or "&&".  Matching the bare word anywhere flags English prose
# in the boot messages - "searching for $CFG file", "pseudo-full install ..." -
# which is noise, and noise in a guard test is how guard tests get deleted.
cmd_pos() {   # COMMAND -> ERE
	printf '(^|[|`(;&])[[:space:]]*%s([[:space:]]|$)' "$1"
}

MISSING=$(missing_commands)

for f in linuxrc finit; do
	SRC="$REPO/initrd-src/$f"
	[ -f "$SRC" ] || continue
	echo "-- $f runs only commands the initrd actually has"
	strip_generated "$SRC" > "$WORK/$f.runnable"
	BAD=""
	for c in $MISSING; do
		grep -qE "$(cmd_pos "$c")" "$WORK/$f.runnable" && BAD="$BAD $c"
	done
	assert_equal "no unavailable command in $f" "" "$(echo $BAD)"
done

# Guards on the guard.  Each of these would otherwise let the test above pass
# while checking nothing.
echo "-- the check is actually capable of failing"
assert_grep "the missing list is non-trivial" "$(missing_commands > "$WORK/missing"; echo "$WORK/missing")" '^dirname$'
assert_equal "awk is known to be missing" "awk" "$(missing_commands | grep '^awk$')"
assert_equal "sed is not, so the list is not just everything" "" "$(missing_commands | grep '^sed$')"

echo "-- stripping generated code did not strip the whole script"
assert_grep "linuxrc still has its own logic" "$WORK/linuxrc.runnable" 'modprobe'
assert_grep "finit still has its own logic"   "$WORK/finit.runnable"   'mount'

echo "-- a planted call is detected"
cp "$WORK/linuxrc.runnable" "$WORK/planted"
echo 'X=`dirname /a/b`' >> "$WORK/planted"
PLANTED=""
for c in $MISSING; do
	grep -qE "$(cmd_pos "$c")" "$WORK/planted" && PLANTED="$PLANTED $c"
done
assert_equal "the planted dirname is found" "dirname" "$(echo $PLANTED)"

finish

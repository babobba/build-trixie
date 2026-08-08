#!/bin/sh
# rootcopy_apply() from finit: copies the rootcopy tree into the overlay, or
# bind-mounts it when the rootmount cheatcode is given.
#
# Bind mounts need root and would dirty the host, so the test shadows `mount`
# with a shell function and records what would have been mounted.
. "$(dirname "$0")/lib.sh"

setup_src() {
	rm -rf "$WORK/src"; mkdir -p "$WORK/src/etc" "$WORK/src/usr/local/bin" "$WORK/src/empty"
	echo "hello" > "$WORK/src/etc/hosts"
	echo "#!/bin/sh" > "$WORK/src/usr/local/bin/tool"
	ln -sf /etc/hosts "$WORK/src/etc/hosts-link"
	mkfifo "$WORK/src/etc/afifo" 2>/dev/null
}

run_rootcopy() {   # $1 = cmdline
	printf ' %s\n' "$1" > "$WORK/cmdline"
	{
		echo 'i=""'
		echo "param() { egrep -qo \" \$1( |\\\$)\" $WORK/cmdline; }"
		echo 'mount() { echo "MOUNT $*" >> '"$WORK"'/mounts; }'
		extract_func "$FINIT" rootcopy_apply | sed "s#/union#$WORK/union#g"
		echo "rootcopy_apply $WORK/src rootcopy"
	} > "$WORK/rc.sh"
	: > "$WORK/mounts"
	sh "$WORK/rc.sh" > "$WORK/output" 2>&1
}

echo "-- default: files are copied"
make_fakeroot; setup_src; run_rootcopy "quiet"
assert_grep   "regular file is copied"  "$WORK/union/etc/hosts" 'hello'
assert_file   "nested file is copied"   "$WORK/union/usr/local/bin/tool"
assert_symlink "symlink is preserved"   "$WORK/union/etc/hosts-link"
assert_equal  "nothing is bind-mounted" "" "$(cat "$WORK/mounts")"

echo "-- rootmount: files are bind-mounted instead"
make_fakeroot; setup_src; run_rootcopy "quiet rootmount"
assert_grep "regular file is bind-mounted"    "$WORK/mounts" 'MOUNT -o bind .*src/etc/hosts '
assert_grep "nested file is bind-mounted"     "$WORK/mounts" 'usr/local/bin/tool'
assert_file "a mount point is created for it" "$WORK/union/usr/local/bin/tool"
assert_not_grep "the overlay copy stays empty" "$WORK/union/etc/hosts" 'hello'

echo "-- rootmount: non-regular entries are handled, not skipped"
# Directories and symlinks cost nothing in the overlay so they are recreated;
# only regular files are bind-mounted, which is where the saving is.
assert_symlink "symlink is recreated"        "$WORK/union/etc/hosts-link" '/etc/hosts'
assert_not_grep "the symlink is not bind-mounted" "$WORK/mounts" 'hosts-link'
[ -d "$WORK/union/empty" ] && _pass "empty directory is recreated" \
	|| _fail "empty directory is recreated" "missing union/empty"
assert_not_grep "directories are not bind-mounted" "$WORK/mounts" 'MOUNT -o bind .*/empty '
[ -p "$WORK/union/etc/afifo" ] && _pass "a fifo is copied, not bind-mounted" \
	|| _fail "a fifo is copied, not bind-mounted" "missing union/etc/afifo"
assert_grep "parent dirs exist for mounted files" "$WORK/mounts" 'usr/local/bin/tool' 

echo "-- a missing rootcopy directory is not an error"
make_fakeroot; rm -rf "$WORK/src"; mkdir -p "$WORK/src"; run_rootcopy "quiet"
assert_equal "exit status is 0" "0" "$?"

finish

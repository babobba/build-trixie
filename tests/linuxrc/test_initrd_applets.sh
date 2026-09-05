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

# ---------------------------------------------------------------- the built initrd
#
# The checks above read the scripts.  The ones below read the initrd that
# mkinitrd actually produced, because two boots have been lost to what it
# copies in rather than to what the scripts say: blockdev shipped with a
# dangling dynamic loader (its symlink copied verbatim from a merged-/usr
# host), and a module missing from the tree is silently dropped from the
# built modlist rather than reported.  ldd cannot be used here - the tree
# carries two C libraries, uClibc for busybox and glibc for the tools copied
# from the build host, and the host's ldd would resolve against the host.
# So every ELF file's interpreter and NEEDED entries are read with readelf
# and resolved by hand along the paths the respective loader searches, inside
# the tree.
#
# These run only when a built initrd exists (build-trixie writes it to
# trixie/isodata/live); without one the script-level checks above still run.
INITRD=${INITRD:-$REPO/trixie/isodata/live/initrd1.xz}

# resolve_in_tree TREE PATH -- follow symlinks as the initrd's kernel would,
# treating absolute targets as tree-relative; print the final path or nothing.
resolve_in_tree() {
	t=$1; p="$1$2"; n=0
	while [ -L "$p" ]; do
		n=$((n + 1)); [ $n -gt 16 ] && return 1
		l=$(readlink "$p")
		case $l in /*) p="$t$l" ;; *) p="$(dirname "$p")/$l" ;; esac
	done
	[ -f "$p" ] && echo "$p"
}

elf_class() { readelf -h "$1" 2>/dev/null | sed -n 's/^ *Class: *//p'; }

# elf_missing TREE -- one line per unresolved interpreter or library:
#   FILE interp PATH | FILE needs LIB | FILE needs LIB (wrong class)
# Kernel modules are ELF too but are resolved by the kernel, not the loader.
elf_missing() {
	tree=$1
	find "$tree" -type f ! -name '*.ko' -size +3 | sort | while read -r f; do
		head -c 4 "$f" | grep -q 'ELF' || continue
		rel=${f#$tree}
		dyn=$(readelf -l -d "$f" 2>/dev/null)
		interp=$(printf '%s\n' "$dyn" | sed -n 's/.*program interpreter: \([^]]*\)\].*/\1/p')
		needed=$(printf '%s\n' "$dyn" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')
		rpath=$(printf '%s\n' "$dyn" | sed -n 's/.*(R\(UN\)*PATH).*\[\(.*\)\]/\2/p' | tr ':' ' ')
		[ -z "$interp$needed" ] && continue       # static
		if [ -n "$interp" ]; then
			resolve_in_tree "$tree" "$interp" >/dev/null || echo "$rel interp $interp"
		fi
		# Library search order: RPATH/RUNPATH, then the loader's compiled-in
		# system directories.  uClibc looks in /lib and /usr/lib; Debian's
		# glibc in the multiarch directories, then /lib and /usr/lib.
		case "$interp $needed" in
			*uClibc*|*libc.so.0*) dirs="$rpath /lib /usr/lib" ;;
			*) dirs="$rpath /lib/x86_64-linux-gnu /usr/lib/x86_64-linux-gnu /lib64 /usr/lib64 /lib /usr/lib" ;;
		esac
		cls=$(elf_class "$f")
		for lib in $needed; do
			hit=""
			for d in $dirs; do
				hit=$(resolve_in_tree "$tree" "$d/$lib") && [ -n "$hit" ] && break
			done
			if [ -z "$hit" ]; then echo "$rel needs $lib"
			elif [ "$(elf_class "$hit")" != "$cls" ]; then echo "$rel needs $lib (wrong class)"
			fi
		done
	done
}

# module_present TREE NAME -- a .ko in the tree or a builtin, either spelling.
# modprobe treats - and _ as the same character, and file names mix them
# (nls_iso8859-1.ko), so each is matched as either.
module_present() {
	re=$(echo "$2" | sed 's/[-_]/[-_]/g')
	mdir=$(echo "$1"/lib/modules/*)
	[ -n "$(find "$mdir/kernel" "$mdir/updates" -regex ".*/$re\.ko" 2>/dev/null)" ] && return 0
	grep -qE "/$re\.ko$" "$mdir/modules.builtin" 2>/dev/null
}

# modules_missing TREE NAMES... -- the names not present.
modules_missing() {
	tree=$1; shift
	for m in "$@"; do module_present "$tree" "$m" || echo "$m"; done
}

if [ ! -f "$INITRD" ]; then
	echo "-- no built initrd at $INITRD: library and module checks skipped"
elif ! command -v readelf >/dev/null 2>&1; then
	echo "-- readelf not installed (binutils): library and module checks skipped"
else
	T="$WORK/initrd"; mkdir -p "$T"
	( cd "$T" && { zstd -dc "$INITRD" 2>/dev/null || xz -dc "$INITRD"; } \
		| cpio -idm --no-preserve-owner 2>/dev/null )
	echo "-- every ELF file in the built initrd finds its loader and libraries"
	assert_file "the initrd unpacked" "$T/bin/busybox"
	elf_missing "$T" > "$WORK/elf-missing"
	assert_equal "no unresolved interpreter or library" "" "$(cat "$WORK/elf-missing")"
	assert_file "blockdev is in the initrd (forensic needs it)" "$T/sbin/blockdev"
	assert_equal "blockdev's loader resolves" "" "$(grep '^/sbin/blockdev' "$WORK/elf-missing")"

	echo "-- every module the boot relies on is in the initrd"
	MDIRS=$(ls -d "$T"/lib/modules/*/ 2>/dev/null | wc -l)
	assert_equal "exactly one kernel's modules" "1" "$MDIRS"
	MDIR=$(echo "$T"/lib/modules/*)
	for idx in modules.alias modules.alias.re modules.dep modules.dep.bb modules.builtin; do
		assert_file "$idx is present" "$MDIR/$idx"
	done
	assert_equal "modules.alias.re is a real pattern list" "yes" \
		"$([ "$(wc -l < "$MDIR/modules.alias.re" 2>/dev/null)" -gt 100 ] && echo yes)"
	# Every name in the source modlist must be in the tree or built in.
	# mkinitrd drops names it cannot find without a word, so a filesystem
	# quietly vanishing from the boot is only visible here.
	assert_equal "every module in initrd-src/modlist is shipped or builtin" "" \
		"$(echo $(modules_missing "$T" $(cat "$REPO/initrd-src/modlist")))"
	assert_equal "the built modlist names only shipped modules" "" \
		"$(echo $(modules_missing "$T" $(cat "$T/modlist" 2>/dev/null)))"
	# Names linuxrc passes to modprobe literally.  The network ones are
	# needed only when the initrd was built with NETWORK other than none.
	LITERAL=$(grep -oE '(^|[;&|`(])[[:space:]]*modprobe([[:space:]]+-[a-z]+)*[[:space:]]+[A-Za-z0-9_-]+' "$WORK/linuxrc.runnable" \
		| sed 's/.*modprobe[[:space:]]*//; s/-[a-z]*[[:space:]]*//g' | sort -u)
	[ -d "$MDIR/kernel/drivers/net" ] || LITERAL=$(echo "$LITERAL" | grep -vE '^(realtek|broadcom|nfsv[34])$')
	assert_grep "the literal list includes scsi_mod" "$(echo "$LITERAL" > "$WORK/literal"; echo "$WORK/literal")" '^scsi_mod$'
	assert_equal "every module linuxrc names literally is shipped or builtin" "" \
		"$(echo $(modules_missing "$T" $LITERAL))"

	echo "-- the initrd checks are capable of failing"
	mv "$T/lib/libuuid.so.1" "$T/lib/libuuid.so.1.hidden"
	assert_grep "hiding libuuid is noticed" "$(elf_missing "$T" > "$WORK/elf-planted"; echo "$WORK/elf-planted")" \
		'^/usr/bin/e2fsck needs libuuid.so.1$'
	mv "$T/lib/libuuid.so.1.hidden" "$T/lib/libuuid.so.1"
	assert_equal "a module that does not exist is reported" "no_such_module" \
		"$(modules_missing "$T" overlay no_such_module)"
fi

finish

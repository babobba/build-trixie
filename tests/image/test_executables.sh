#!/bin/sh
# Can every program on the image start?
#
# Not "does it work" - the cheatcode and image tests are for that - but the
# quieter failure: a program whose shared library, interpreter, symlink
# target, alternative or terminfo is missing, which fails at the first
# launch and nowhere before. Packages removed from the image (perl, synaptic)
# and the stripping of docs and locales are how that happens here.
#
# The image is checked as the booted system sees it: the base squashfs with
# every module on the medium layered on top, a tmpfs upper so nothing is
# written to the image, and a chroot so the image's own dynamic loader and
# tools do the checking rather than the host's.
#
# Five checks:
#   1. adequate --all, Debian's checker for an installed system: missing
#      libraries, undefined symbols, broken symlinks, missing alternatives
#      and binfmt interpreters, for everything that came from a package.
#   2. ldd over every ELF file in the program and plugin directories, which
#      also covers what the overlay and the dog packages put there by hand.
#   3. Every script in /usr/local/bin and /usr/local/sbin: its interpreter
#      exists, it parses, and every program it calls resolves.
#   4. Every .desktop file validates and its Exec resolves.
#   5. Every alternative and every symlink under /usr points at something.
#
# BREAK=1 runs the same checks against an image with one library hidden and
# passes only if they fail - the proof that the test can fail at all.
. "$(dirname "$0")/lib.sh"
mount_image "$@"
[ "$(id -u)" = 0 ] || skip "the chroot and the overlay need root"
grep -q overlay /proc/filesystems || skip "the host kernel has no overlayfs"

# ------------------------------------------------- the booted view, in a chroot
OVB=${OVB:-/tmp/image-ov-$(basename "$0" .sh)}
OV=$OVB/root
# The overlay's own mounts are taken down first; the image mount the library
# made comes last and only at exit - taking it down at the start, as a first
# version did, removed the lower directory before the overlay was stacked.
ov_cleanup() {
	umount "$OV/proc" 2>/dev/null; umount "$OV" 2>/dev/null
	for m in "$OVB"/mod-*; do [ -d "$m" ] && umount "$m" 2>/dev/null; done
	umount "$OVB/tmp" 2>/dev/null; rm -rf "$OVB"
}
trap 'ov_cleanup; umount "$MNT" 2>/dev/null; rmdir "$MNT" 2>/dev/null' EXIT INT TERM
ov_cleanup 2>/dev/null; mkdir -p "$OV" "$OVB/tmp"
# upper and work must not live on an overlay themselves; a tmpfs is always fine
mount -t tmpfs -o size=512m tmpfs "$OVB/tmp" || skip "could not mount a tmpfs for the upper layer"
mkdir -p "$OVB/tmp/up" "$OVB/tmp/wk"
LOWER=$ROOT; NMOD=0
for sq in "$ISODATA"/live/[0-9]*-*.squashfs; do
	[ -f "$sq" ] || continue
	case "$sq" in */01-filesystem.squashfs) continue ;; esac
	NMOD=$((NMOD+1)); m="$OVB/mod-$NMOD"; mkdir -p "$m"
	mount -o loop,ro "$sq" "$m" 2>/dev/null && LOWER="$m:$LOWER" || echo "   could not mount module $(basename "$sq"), checked without it"
done
mount -t overlay overlay -o "lowerdir=$LOWER,upperdir=$OVB/tmp/up,workdir=$OVB/tmp/wk" "$OV" \
	|| skip "could not stack the overlay"
mount -t proc proc "$OV/proc" 2>/dev/null
echo "   checking the base with $NMOD module(s) layered on top"

if [ "${BREAK:-0}" = 1 ]; then
	# Hide a library nearly everything graphical links to. Removing it through
	# the mounted overlay writes a whiteout into the tmpfs upper layer; the
	# image itself is untouched.
	LIB=/usr/lib/x86_64-linux-gnu/libgtk-3.so.0
	[ -e "$OV$LIB" ] || skip "BREAK=1 needs libgtk-3 on the image to hide"
	rm -f "$OV$LIB"
	[ -e "$OV$LIB" ] && skip "BREAK=1 could not hide $LIB"
	echo "   BREAK=1: $LIB hidden; the checks below are expected to fail"
fi

ch() { chroot "$OV" "$@"; }

# ------------------------------------------------------------- 1. adequate
echo "-- adequate: what Debian's own checker says about the installed packages"
if [ -x "$OV/usr/bin/adequate" ]; then
	ch adequate --all > "$WORK/adequate.txt" 2>&1
	NTAG=$(grep -c '^[^ ]*: ' "$WORK/adequate.txt" | tr -d ' ')
	echo "   $NTAG finding(s) in total; the fatal kinds must be absent"
	# broken-symlink findings inside the manual, doc and locale trees are the
	# build's own stripping (see test_dpkg_verify); a broken link anywhere
	# else is real.
	for tag in library-not-found undefined-symbol broken-symlink missing-alternative missing-binfmt-interpreter missing-binfmt-detector; do
		# Documentation is stripped from the image, so links into it dangle
		# by design; ghostscript's CJK font map points at a package that is
		# only recommended and is not on the image; a .DirIcon and the SendTo
		# links under rox.sourceforge.net are ROX-Filer decorations for a file
		# manager that is not shipped, and /usr/local/cr-initrd is the initrd
		# source tree, whose links resolve only once it is the initrd.
		# libqt5core5t64's qtchooser default.conf points into the qtchooser
		# package, which is only recommended; it selects a Qt for qmake and
		# means nothing to a program that runs.
		assert_empty "adequate: no $tag" "$(grep " $tag" "$WORK/adequate.txt" | grep -vE ' /usr/share/(doc|doc-base|man|info|locale|help|ghostscript)/| /usr/local/cr-initrd/|/\.DirIcon |/rox\.sourceforge\.net/|/qtchooser/' | head -5 | tr '\n' ' ')"
	done
else
	_fail "adequate is on the image" "the build installs it so this check can run offline"
fi

# --------------------------------------------------------- 2. ldd everything
echo "-- every ELF file in the program and plugin directories finds its libraries"
DIRS="usr/bin usr/sbin usr/libexec usr/local/bin usr/local/sbin usr/lib/xorg usr/lib/firefox-esr usr/lib/x86_64-linux-gnu"
( cd "$OV" && find $DIRS -xdev -type f -size +1k 2>/dev/null | while read -r f; do
	[ "$(head -c4 "$f" 2>/dev/null | tr -d '\0' | cut -c2-4)" = ELF ] && echo "/$f"; done ) > "$WORK/elf.list"
NELF=$(wc -l < "$WORK/elf.list" | tr -d ' ')
# ldd takes many files at once and prefixes each block with "file:". It is
# run one directory at a time with that directory on the library path: an
# application's private libraries (Firefox's libnss3 and friends) carry no
# RUNPATH and are found through the application's own directory at run time,
# and a check that ignored that would report every one of them.
: > "$WORK/ldd-missing.txt"
# The path is the directory and every directory above it down to /usr/lib,
# since an application's plugins (Firefox's gmp-clearkey) load with the
# application's own directory on the path. /bin/true is added to every
# batch so ldd always prints the "file:" header it omits for a lone file.
for d in $(sed 's|/[^/]*$||' "$WORK/elf.list" | sort -u); do
	LP=$d; a=$d; while [ "$a" != /usr/lib ] && [ "$a" != /usr ] && [ "$a" != / ]; do a=${a%/*}; [ -n "$a" ] && LP="$LP:$a"; done
	{ echo /bin/true; grep "^$d/[^/]*$" "$WORK/elf.list"; } | xargs -n 200 chroot "$OV" env LD_LIBRARY_PATH="$LP" /usr/bin/ldd 2>/dev/null \
		| awk '/^\/.*:$/ { f=$1 } / => not found/ || /not found$/ { print f, $1 }' >> "$WORK/ldd-missing.txt"
done
# libcaca's OpenGL output plugin is dlopen'd on demand and links libGLU and
# libglut, which the package does not depend on; nothing on the image asks
# caca for an OpenGL window.
grep -v '/caca/libgl_plugin\.so' "$WORK/ldd-missing.txt" > "$WORK/ldd-missing.tmp"; mv "$WORK/ldd-missing.tmp" "$WORK/ldd-missing.txt"
sort -u -o "$WORK/ldd-missing.txt" "$WORK/ldd-missing.txt"
echo "   $NELF ELF files checked"
# An ELF program of another architecture (a 32-bit binary in a hand-built
# package) fails with "No such file or directory" from the kernel, which
# ldd does not report. The class byte says so up front: 2 is 64-bit.
: > "$WORK/elf-foreign.txt"
grep -E '^/usr/(bin|sbin|local/bin|local/sbin)/' "$WORK/elf.list" | while read -r f; do
	[ "$(head -c5 "$OV$f" 2>/dev/null | tail -c1 | od -An -tu1 | tr -d ' ')" = 2 ] || echo "$f" >> "$WORK/elf-foreign.txt"
done
assert_empty "no program is built for another architecture" "$(head -8 "$WORK/elf-foreign.txt" | tr '\n' ' ')"
[ "$NELF" -gt 500 ] && _pass "the scan found the image's programs" || _fail "the scan found the image's programs" "only $NELF ELF files - is the tree what it should be?"
assert_empty "no ELF file is missing a library" "$(head -8 "$WORK/ldd-missing.txt" | tr '\n' ' ')"

# ---------------------------------------------------------------- 3. scripts
echo "-- the scripts in /usr/local: interpreter, syntax, and the programs they call"
KEYWORDS="if then else elif fi for while until do done case esac in function return exit break continue local export set unset shift eval exec source trap read echo printf test true false cd pwd type command builtin let declare typeset readonly wait kill getopts hash times ulimit umask alias unalias pushd popd dirs jobs fg bg disown select time coproc mapfile readarray caller enable help logout suspend"
# shell functions a script gets by sourcing gettext.sh
KEYWORDS="$KEYWORDS eval_gettext eval_ngettext eval_pgettext eval_npgettext"
# Programs a dog script calls that are not on every image and are checked for
# at run time by the script itself, so their absence here is not a fault.
# Commands a script probes for or provides itself, so their absence is not
# a defect: packit tries every archiver it knows through which(1); pman
# renders manual pages, which the image strips; peasywifi links udhcpc from
# busybox at run time; probepart is the Puppy helper conv-sfs reaches for on
# the partition-type path; rox -D is a ROX-Filer window refresh; rxvt is
# filemnt's prompt for an encrypted image, a path that also needs Puppy's
# losetup-FULL; peasyprint is the sibling tool peasyglue hands its result to
# when it is installed; timedatectl is systemd's, and the two ntp scripts
# that call it silence the error on a sysvinit image and carry on.
OPTIONAL="gksu gksudo pkexec xterm-launcher nvidia-detect flatpak snap sfsload-gui live-boot-helper
rar zip man2html nroff udhcpc probepart rox rxvt peasyprint timedatectl"
OPTIONAL=$(echo $OPTIONAL)   # one line, so the " word " lookups below match
: > "$WORK/script-interp.txt"; : > "$WORK/script-syntax.txt"; : > "$WORK/script-cmds.txt"; NSCR=0
FUNCS=$(grep -hoE '^[[:space:]]*(function[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)|^[[:space:]]*function[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' "$OV"/usr/local/bin/* "$OV"/usr/local/sbin/* 2>/dev/null | sed -E 's/function[[:space:]]+//; s/[[:space:]]*\(\)//; s/^[[:space:]]*//' | sort -u)
for f in "$OV"/usr/local/bin/* "$OV"/usr/local/sbin/*; do
	[ -f "$f" ] || continue
	head -c2 "$f" 2>/dev/null | grep -q '^#!' || continue
	NSCR=$((NSCR+1)); rel=${f#$OV}
	interp=$(sed -n '1s/^#![[:space:]]*//p' "$f" | awk '{print $1}')
	case "$interp" in /usr/bin/env) interp=$(sed -n '1s/^#![[:space:]]*//p' "$f" | awk '{print $2}'); interp=$(ch sh -c "command -v $interp" 2>/dev/null) ;; esac
	[ -n "$interp" ] && [ -e "$OV$interp" ] || echo "$rel: interpreter '$interp'" >> "$WORK/script-interp.txt"
	case "$interp" in
		*/sh|*/bash|*/dash) ch "$interp" -n "$rel" 2>/dev/null || echo "$rel" >> "$WORK/script-syntax.txt"
			# command-position words: after a line start or a control operator
			# heredoc bodies are data, and the pattern half of a case arm
			# ("upgrade|dist-upgrade)") is not a command
			awk -f "$TESTDIR/cmdwords.awk" "$f" \
			  | sed -E 's/&[a-z]+;//g' \
			  | tr ';|&`' '\n\n\n\n' | sed -E 's/\$\(/\n/g; s/^[[:space:]]*(if|then|else|elif|while|until|do|time|!|\{|\()[[:space:]]+/\n/' \
			  | awk '{ w=$1; if (w ~ /^[a-z][a-z0-9_.+-]+$/ && length(w) > 1) print w }' | sort -u \
			  | while read -r w; do
				echo " $KEYWORDS " | grep -q " $w " && continue
				echo "$FUNCS" | grep -qx "$w" && continue
				echo " $OPTIONAL " | grep -q " $w " && continue
				ch sh -c "command -v -- '$w' >/dev/null 2>&1" && continue
				# a script that asks which/command -v/type for it first has
				# made it optional itself
				grep -qE "(which|command -v|type)[[:space:]]+(-[a-z]+[[:space:]]+)?$w([^A-Za-z0-9_.+-]|$)|-[xef][[:space:]]+[^[:space:]]*/$w([^A-Za-z0-9_.+-]|$)" "$f" && continue
				echo "$rel: $w" >> "$WORK/script-cmds.txt"
			  done ;;
	esac
done
echo "   $NSCR scripts checked"
assert_empty "every script's interpreter exists"        "$(head -5 "$WORK/script-interp.txt" | tr '\n' ' ')"
assert_empty "every shell script parses"                "$(head -5 "$WORK/script-syntax.txt" | tr '\n' ' ')"
assert_empty "every program a script calls is present"  "$(sort -u "$WORK/script-cmds.txt" | head -12 | tr '\n' ' ')"

# --------------------------------------------------------- 4. desktop entries
echo "-- every menu entry validates and points at a program that exists"
: > "$WORK/desktop-bad.txt"; : > "$WORK/desktop-exec.txt"; NDESK=0
for d in "$OV"/usr/share/applications/*.desktop "$OV"/usr/local/share/applications/*.desktop; do
	[ -f "$d" ] || continue; NDESK=$((NDESK+1)); rel=${d#$OV}
	# desktop-file-validate also objects to unregistered Categories values and
	# icon names with an extension; those do not stop a launch, so only what
	# would - a missing or malformed Exec, Type or Name, or a file it cannot
	# parse - counts.
	# an apostrophe or ~ in an Exec value is a spec violation every launcher copes with
	ch desktop-file-validate "$rel" 2>&1 | grep 'error' | grep -v 'reserved character' | grep -qE 'key "(Exec|TryExec|Type|Name)"|required key|does not exist|parse|not a valid' \
		&& echo "$rel" >> "$WORK/desktop-bad.txt"
	# TryExec names a program whose absence hides the entry (vim.desktop
	# from vim-common on an image with only vim-tiny): that is the spec
	# working, not a broken entry, so such an entry is left alone
	if t=$(sed -n 's/^TryExec=//p' "$d" | head -1) && [ -n "$t" ]; then
		ch sh -c "command -v -- '$t' >/dev/null 2>&1" || continue
	fi
	for key in TryExec Exec; do
		x=$(sed -n "s/^$key=//p" "$d" | head -1 | sed -E 's/^(env[[:space:]]+([A-Za-z_]+=[^[:space:]]*[[:space:]]+)*)//' | awk '{print $1}' | tr -d '"')
		[ -n "$x" ] || continue
		ch sh -c "command -v -- '$x' >/dev/null 2>&1" || echo "$rel: $key=$x" >> "$WORK/desktop-exec.txt"
	done
done
echo "   $NDESK entries checked"
assert_empty "no .desktop file has validation errors" "$(head -5 "$WORK/desktop-bad.txt" | tr '\n' ' ')"
assert_empty "every Exec resolves"                    "$(sort -u "$WORK/desktop-exec.txt" | head -8 | tr '\n' ' ')"

# ------------------------------------------------- 5. alternatives and symlinks
echo "-- alternatives and symlinks point at something"
: > "$WORK/alt-bad.txt"
# Absolute link targets have to be resolved inside the chroot - resolved on
# the host, /lib/apt/... points nowhere. And the build strips manual pages,
# docs and locales, so an alternative's manual-page slave link and a symlink
# into those trees are expected to dangle, as test_dpkg_verify expects the
# files themselves to be gone.
STRIPPED='^/usr/share/(doc|doc-base|man|info|locale|help)/'
for l in "$OV"/etc/alternatives/*; do
	[ -L "$l" ] || continue; t=$(readlink "$l"); case "$t" in /*) ;; *) t=/etc/alternatives/$t ;; esac
	echo "$t" | grep -qE "$STRIPPED" && continue
	ch test -e "$t" || echo "${l#$OV} -> $t" >> "$WORK/alt-bad.txt"
done
assert_empty "every alternative resolves" "$(head -5 "$WORK/alt-bad.txt" | tr '\n' ' ')"
# /usr/local/cr-initrd is upgrade-kernel's initramfs skeleton, busybox links
# and all; it is assembled elsewhere and is not the live tree.
DANGLING=$(ch find /usr/bin /usr/sbin /usr/lib /usr/local /usr/share/applications /etc/alternatives -path /usr/local/cr-initrd -prune -o -xtype l -print 2>/dev/null \
	| while read -r l; do t=$(ch readlink -f "$l" 2>/dev/null); echo "$t" | grep -qE "$STRIPPED" || echo "$l"; done | grep -v '/qtchooser/' | head -8 | tr '\n' ' ')
assert_empty "no dangling symlink under /usr or /etc/alternatives" "$DANGLING"

if [ "${BREAK:-0}" = 1 ]; then
	# The run is a pass only if the hidden library was reported missing by
	# the ldd check - not if some other check happened to fail.
	echo; if grep -q 'libgtk-3.so.0' "$WORK/ldd-missing.txt"; then
		echo "BREAK=1: the hidden library was reported by $(grep -c 'libgtk-3.so.0' "$WORK/ldd-missing.txt") program(s) - the test can fail. PASS"; exit 0
	else echo "BREAK=1: the hidden library went unreported - the test cannot fail. FAIL"; exit 1; fi
fi
finish

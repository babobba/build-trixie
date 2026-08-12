#!/bin/sh
# Does the built root filesystem follow the FHS?
#
# Checked against FHS 3.0, the version Debian Policy references. Only the parts
# that are actually mandatory are asserted; where the standard says "may" this
# stays quiet, because a conformance test that flags optional things is a test
# people learn to ignore.
#
# The image is Devuan excalibur (a Debian trixie derivative), so Debian's own
# choices - merged /usr in particular - are treated as the expected shape.
. "$(dirname "$0")/lib.sh"
mount_image "$@"

echo "-- required top-level directories (FHS 3)"
for d in bin boot dev etc lib media mnt opt root run sbin srv tmp usr var; do
	assert_dir "/$d exists" "$ROOT/$d"
done

echo "-- nothing unexpected at the top level"
# /live is where the live system's own squashfs modules and boot data go, and
# /home is optional-but-normal. Everything else here should be FHS.
ALLOWED=" bin boot dev etc home lib lib32 lib64 libx32 live media mnt opt proc root run sbin srv sys tmp usr var "
EXTRA=
for e in $(ls -1 "$ROOT"); do
	case "$ALLOWED" in *" $e "*) ;; *) EXTRA="$EXTRA $e" ;; esac
done
assert_empty "no unexplained top-level entries" "$EXTRA"

echo "-- merged /usr, as Debian trixie and later require"
assert_symlink "/bin is a symlink"  "$ROOT/bin"  "usr/bin"
assert_symlink "/sbin is a symlink" "$ROOT/sbin" "usr/sbin"
assert_symlink "/lib is a symlink"  "$ROOT/lib"  "usr/lib"

echo "-- required /usr and /var subdirectories (FHS 4.1, 5.1)"
for d in bin lib local sbin share; do assert_dir "/usr/$d exists" "$ROOT/usr/$d"; done
for d in cache lib log spool tmp; do assert_dir "/var/$d exists" "$ROOT/var/$d"; done

echo "-- /usr/local skeleton (FHS 4.9)"
for d in bin etc games include lib man sbin share src; do
	assert_dir "/usr/local/$d exists" "$ROOT/usr/local/$d"
done

echo "-- world-writable temp directories carry the sticky bit (FHS 3.15, 5.15)"
assert_mode "/tmp is 1777"     "$ROOT/tmp"     1777
assert_mode "/var/tmp is 1777" "$ROOT/var/tmp" 1777

echo "-- no subdirectories in the binary directories (FHS 3.4.1, 3.16.1)"
# Followed through the merged-/usr symlinks, since that is where the files are.
SUBDIRS=$(find "$ROOT/usr/bin" "$ROOT/usr/sbin" -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
	| sed "s|$ROOT||" | tr '\n' ' ')
assert_empty "usr/bin and usr/sbin hold only files" "$SUBDIRS"

echo "-- no binaries under /etc (FHS 3.7.1)"
# "Binaries" means compiled executables; the shell scripts in init.d and cron.d
# are what /etc is for. Detected by the ELF magic, not by file extension.
#
# One known violation, listed so that a *new* binary in /etc still fails:
# /etc/skel/Startup/peasywifi_tray is a stripped 2017 x86-64 executable shipped
# by the peasywifi package from the DebianDog repository. Fixing it means
# patching that package to put the binary in /usr/bin and leave a launcher in
# skel, which is upstream's call rather than this build's.
ETC_ELF_KNOWN=" /etc/skel/Startup/peasywifi_tray "
ELF=""; KNOWN_SEEN=""
for f in $(find "$ROOT/etc" -type f 2>/dev/null); do
	head -c4 "$f" 2>/dev/null | grep -q 'ELF' || continue
	rel=${f#$ROOT}
	case "$ETC_ELF_KNOWN" in
		*" $rel "*) KNOWN_SEEN="$KNOWN_SEEN $rel" ;;
		*)          ELF="$ELF $rel" ;;
	esac
done
assert_empty "no undocumented ELF binary under /etc" "$ELF"
# The exception must still describe reality; a stale entry would silently widen
# the check.
assert_equal "the documented exception is still the one that is there" \
	"$(echo $ETC_ELF_KNOWN)" "$(echo $KNOWN_SEEN)"

echo "-- removable media (FHS 3.11)"
# FHS reserves /mnt for temporary mounts by the system administrator, and gives
# removable media /media. This image inherits Porteus's habit of mounting every
# discovered filesystem under /mnt/<device> from the initrd, so /media exists
# and stays empty. Recorded rather than asserted: changing the mount root moves
# every path a user has ever put in a changes= or magic-folder line, so it is a
# decision, not a bug to quietly fix.
assert_dir "/media exists" "$ROOT/media"
IRD=$(unpack_initrd) || IRD=
if [ -n "$IRD" ]; then
	xfail "the initrd mounts discovered media under /media" \
		grep -q 'mkdir /media/\$DEV\|mount .*/media/\$DEV' "$IRD/linuxrc"
	# Guard: if the grep target disappears the xfail above would sit there
	# passing forever while checking nothing.
	assert_equal "the initrd does mount devices somewhere under a fixed root" "yes" \
		"$(grep -q '/mnt/\$DEV' "$IRD/linuxrc" && echo yes)"
else
	echo "  (initrd not unpacked - skipping the mount-root check)"
fi

finish

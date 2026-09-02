#!/bin/sh
# Boot test for magic folders and the nomagic cheatcode.
#
# Magic folders bind real storage over paths in the live system from inside the
# initrd, before anything else can look at those paths. Two things need proving
# on a real boot and cannot be proved by a unit test: that a bind made in the
# initrd is still there in the booted system, and that a pairing which would
# break the boot is refused rather than attempted.
#
# nomagic exists because a bad pairing otherwise leaves no way to boot past it,
# so the same ISO is booted twice - once letting the folders bind, once with
# nomagic - and the second boot must show the first boot's effect absent.
# The two runs need separate work directories, and the name should say which
# of the two behaviours is being checked.
case "${CODES:-}" in *nomagic*) NAME=${NAME:-nomagic} ;; *) NAME=${NAME:-magic} ;; esac
SCRATCH=1

# The scratch disk is the guest's second drive, but which name it lands on
# depends on how the guest enumerates IDE, so both candidates are listed. The
# one that does not exist exercises the "source not found" path, which is worth
# a check of its own.
bt_extra_setup() {
	mkdir -p "$WORK/iso/live/rootcopy/etc"
	cat > "$WORK/iso/live/rootcopy/etc/magic_folders" <<'MFEOF'
# a comment, and the blank line below, must both be skipped

/mnt/sda1/magicsrc	/opt/magic
/mnt/sdb1/magicsrc	/opt/magic
/mnt/sda1/magicsrc	/opt/nowhere/../escaped
relative/source		relative-target
/mnt/sda1/magicsrc	/proc
/mnt/sda1/magicsrc
/mnt/sda1/definitely-not-here	/opt/missing
MFEOF
}

REPORT='
echo "MAGIC=$(cat /opt/magic/hello 2>/dev/null || echo ABSENT)"
echo "MAGICMOUNT=$(grep -c " /opt/magic " /proc/mounts)"
# Print the line rather than a count: a count that comes back 0 cannot tell
# you whether /proc was clobbered or the pattern was simply wrong, and the
# first guess at this pattern was wrong.
echo "PROCLINE=$(grep " /proc " /proc/mounts 2>/dev/null | head -1)"
echo "PROCBOUND=$(grep -c "magicsrc /proc " /proc/mounts)"
echo "ESCAPED=$(test -e /opt/escaped && echo PRESENT || echo ABSENT)"
echo "MISSING=$(test -e /opt/missing/hello && echo PRESENT || echo ABSENT)"
'
. "$(dirname "$0")/boot-lib.sh"

bt_build
bt_boot

echo "== results"
bt_check "the system booted at all" '===CLI-END==='
case "$CODES" in
  *nomagic*)
	bt_check "nomagic says so on the console"       'nomagic - skipping magic folders'
	bt_check "the magic folder was not bound"       '^MAGIC=ABSENT$'
	bt_check "and nothing is mounted at the target" '^MAGICMOUNT=0$' ;;
  *)
	# Without this the checks below could all pass on a boot where the
	# scratch disk was never mounted in the first place.
	bt_check "the magic folder was bound"           '^MAGIC=from the scratch disk$'
	bt_check "the target is a real mountpoint"      '^MAGICMOUNT=1$'
	bt_check "one source was reported missing"      'skipping /opt/missing - source'
	bt_check "a relative target is refused"         'target must be an absolute path'
	bt_check "a target containing .. is refused"    "target may not contain"
	bt_check "a pair with no target is refused"     'no target given'
	bt_check "binding over /proc is refused"        'refusing /proc'
	bt_check "and /proc really is still procfs"     '^PROCLINE=[^ ]* /proc proc '
	bt_check_not "nothing was bound over /proc"     '^PROCBOUND=[1-9]'
	bt_check "the .. target was not created"        '^ESCAPED=ABSENT$'
	bt_check "the missing source bound nothing"     '^MISSING=ABSENT$' ;;
esac
bt_finish

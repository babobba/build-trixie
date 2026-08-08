#!/bin/sh
# cfgfile= / sgnfile= : the marker file used to find the boot medium
. "$(dirname "$0")/lib.sh"

resolve_cfg() {   # $1 = cmdline -> prints the resolved marker
	printf ' %s\n' "$1" > "$WORK/cmdline"
	{
		echo "value() { egrep -o \" \$1=[^ ]+\" $WORK/cmdline | cut -d= -f2; }"
		extract_region '^CFG=`value cfgfile`' '^FROM='
		echo 'echo "$CFG"'
	} > "$WORK/cfg.sh"
	sh "$WORK/cfg.sh" 2>/dev/null
}

assert_equal "default marker is the initrd"      "initrd1.xz"  "$(resolve_cfg 'quiet from=/')"
assert_equal "cfgfile= is honoured"              "my.cfg"      "$(resolve_cfg 'quiet cfgfile=my.cfg')"
assert_equal "sgnfile= is honoured (Porteus)"    "porteus.sgn" "$(resolve_cfg 'quiet sgnfile=porteus.sgn')"
assert_equal "cfgfile= wins when both are given" "my.cfg"      "$(resolve_cfg 'quiet cfgfile=my.cfg sgnfile=porteus.sgn')"
assert_equal "a .sgn name survives verbatim"     "DebLive-x86_64.sgn" \
	"$(resolve_cfg 'quiet sgnfile=DebLive-x86_64.sgn')"

# The marker is searched for under live/, and a marker that cannot be found is
# fatal rather than silently ignored -- guard the line that decides that.
assert_grep "the marker is searched under live/" "$LINUXRC" 'search -e live/\$CFG'
assert_grep "a missing marker is fatal"          "$LINUXRC" '&& PTH=\$CFGDEV/\$FOLDER || \. fatal'

finish

#!/bin/sh
# Where does the wall-clock time go between power-on and a painted desktop?
#
# Not a pass/fail test: it boots the image once with every stage stamped from
# /proc/uptime and prints a timeline. The boot is invisible to the clock by
# default - linuxrc silences printk in its second line, so from "Run /init" to
# the first systemd message nothing on the serial log carries a time - and
# this fills that gap without touching the shipped scripts. The initrd is
# repacked from initrd-src exactly as the boot tests do, then instrumented in a
# scratch copy: every `echo $i"..."` stage line becomes a stamped one and a few
# extra stamps bracket the silent blocks (the modprobe loop, the device scan,
# the squashfs mounts, the pivot).
#
# Inside the booted system the guiexec hook, which runs once the desktop has
# started, asks systemd for its own view (systemd-analyze time/blame/
# critical-chain, journal timestamps) and reads process start times for the
# X/desktop path, which systemd knows nothing about.
#
# Everything here runs under QEMU TCG - no KVM in the build container - so the
# absolute numbers are several times what hardware would show. The shape is
# what matters: which stage is a fixed wait, which scales with the image, and
# which is emulation overhead that will shrink on its own.
NAME=${NAME:-profile}
CODES="${CODES:-login=root}"
. "$(dirname "$0")/boot-lib.sh"

# Stamp helper for the initrd's busybox sh. `read` is a builtin, so it is one
# syscall - the stamp does not cost what it measures.
PROF_FN='prof() { read _up _ < /proc/uptime; echo "PROF $_up $*"; }'

bt_extra_setup() {
	P="$WORK/prof-ird"; rm -rf "$P"; mkdir -p "$P"
	( cd "$P" && xz -dc "$WORK/iso/live/initrd1.xz" | cpio -idm --quiet 2>/dev/null ) \
		|| bt_fail "could not unpack the repacked initrd"
	L="$P/linuxrc"
	# Define prof right after printk is silenced (/proc is mounted by then).
	sed -i "s|^echo 0 >/proc/sys/kernel/printk\$|&\n$PROF_FN\nprof 'linuxrc started'|" "$L"
	# Every stage line becomes a stamped one.
	sed -i 's/echo \$i"/prof "/g' "$L"
	# Stamps around the blocks that print nothing of their own.
	sed -i '0,/^mount -nt devtmpfs none \/dev$/s//prof "modprobe loop done"\n&/' "$L"
	sed -i '0,/^fstab$/s//prof "fstab: scanning block devices"\n&/' "$L"
	sed -i 's/^\([[:space:]]*\)for MODULE in `sed .s\/ \/\\n\/g. modlist | grep ata_`$/\1prof "unloading ata modules"\n&/' "$L"
	sed -i 's/^rm -r \/lib\/\* \/usr\/\*$/&\nprof "initrd cleaned"/' "$L"
	sed -i 's/^\([[:space:]]*\)pivot_root \/union \/union\/run\/initramfs$/\1prof "pivot_root - handing off to systemd"\n&/' "$L"
	# finit is the union assembler; stamp each module it mounts.
	F="$P/finit"
	if [ -f "$F" ]; then
		sed -i "1a $PROF_FN" "$F"
		sed -i 's/echo "  \$m  \([^"]*\)"/prof "  -> \1"/g' "$F"
		sed -i 's|^mount -t overlay -o upperdir=\$UPPERDIR,lowerdir=\$LOWLIST,workdir=\$WORKDIR overlay /union$|&\nprof "overlay union mounted"|' "$F"
	fi
	# PROF_FINE=1 stamps every modprobe in the loop (215 lines) and the
	# login-to-desktop scripts, which live in the rootfs rather than the initrd
	# and are delivered here through rootcopy. /etc/profile and root's openbox
	# autostart are taken from the image so the stamped copies differ from the
	# shipped ones only by the stamps.
	if [ "${PROF_FINE:-0}" = 1 ]; then
		sed -i 's/^modprobe \$MODULE 2> \/dev\/null$/prof "modprobe $MODULE"; &/' "$L"
		RC="$WORK/iso/live/rootcopy"; X="$WORK/sqx"; rm -rf "$X"
		unsquashfs -q -f -d "$X" "$ISODATA/live/01-filesystem.squashfs" \
			etc/profile root/.config/openbox/autostart >/dev/null 2>&1 \
			|| bt_fail "could not extract /etc/profile and the autostart from the squashfs"
		GPROF='prof() { read _up _ < /proc/uptime; echo "PROF $_up $*" > /dev/ttyS0; }'
		mkdir -p "$RC/etc" "$RC/root/.config/openbox"
		{ echo "$GPROF"; sed 's/^sleep 3$/prof "profile: sleep 3 before startx"; sleep 3; prof "profile: startx"/' "$X/etc/profile"; } > "$RC/etc/profile"
		{ echo '#!/bin/sh'; echo "$GPROF"; echo 'prof "autostart: begin"'
		  sed -e 's/^pcmanfm --desktop &$/prof "autostart: pcmanfm+lxpanel"; &/' \
		      -e 's/^sleep 8$/prof "autostart: sleep 8"; sleep 8; prof "autostart: after sleep"/' \
		      -e 's/^volumeicon &$/prof "autostart: volumeicon"; &/' "$X/root/.config/openbox/autostart"
		  echo 'prof "autostart: end of the shipped script"'; } > "$RC/root/.config/openbox/autostart"
		chmod 644 "$RC/etc/profile"; chmod 755 "$RC/root/.config/openbox/autostart"
		echo "   fine mode: per-modprobe stamps, stamped /etc/profile and openbox autostart"
	fi
	grep -c '^PROF\|prof ' "$L" >/dev/null || bt_fail "instrumentation did not apply"
	( cd "$P" && find . | cpio -o -H newc --quiet 2>/dev/null | xz -f --check=crc32 ) \
		> "$WORK/iso/live/initrd1.xz" || bt_fail "could not repack the instrumented initrd"
	echo "   instrumented linuxrc: $(grep -c 'prof ' "$L") stamps, finit: $(grep -c 'prof ' "$F" 2>/dev/null || echo 0)"

	# The desktop-side report. Written over the stock rgui: the analysis goes
	# first and the marker last, because bt_boot stops watching (and kills the
	# guest) as soon as it sees the marker.
	cat > "$WORK/iso/live/rootcopy/usr/local/bin/rgui" <<'RGUI'
#!/bin/sh
exec > /dev/ttyS0 2>&1
read UP _ < /proc/uptime; echo "PROF $UP guiexec (desktop autostart reached)"
echo "===GUI-REPORT==="
echo "---systemd-analyze time---"; systemd-analyze time 2>&1
echo "---systemd-analyze blame (top 25)---"; systemd-analyze blame --no-pager 2>&1 | head -25
echo "---critical-chain graphical.target---"; systemd-analyze critical-chain --no-pager graphical.target 2>&1 | head -30
echo "---critical-chain multi-user.target---"; systemd-analyze critical-chain --no-pager multi-user.target 2>&1 | head -30
echo "---journal milestones (monotonic)---"
journalctl -b -o short-monotonic --no-pager 2>/dev/null | grep -aE 'Startup finished|Reached target .*(sysinit|basic|multi-user|graphical|network-online)|getty@tty1|Coldplug|udev-settle|wait-online|Timed out|took [0-9.]+s|cliexec-cheat|rc.local|Removed slice|apt-daily|e2scrub|fstrim' | head -40
echo "---process start times (uptime - etimes)---"
NOW=$(cut -d' ' -f1 /proc/uptime | cut -d. -f1)
ps -eo etimes,pid,comm --sort=-etimes 2>/dev/null | awk -v now="$NOW" 'NR>1 && $3 ~ /^(agetty|login|bash|sh|startx|xinit|Xorg|X|openbox|pcmanfm|lxpanel|conky|dbus-daemon|rcli|cliexec-cheat|rc.local|systemd|systemd-udevd|systemd-journal)$/ { printf "  %6ds  %s (pid %s)\n", now-$1, $3, $2 }'
echo "---X server: first/last log stamp and the 8 biggest gaps inside---"
for f in /var/log/Xorg.0.log /root/.local/share/xorg/Xorg.0.log; do [ -f "$f" ] || continue
	echo "  $f: $(grep -aoE '^\[ *[0-9.]+\]' "$f" | sed -n '1p' | tr -d '[] ') -> $(grep -aoE '^\[ *[0-9.]+\]' "$f" | tail -1 | tr -d '[] ')"
	grep -aE '^\[ *[0-9.]+\]' "$f" | sed -E 's/^\[ *([0-9.]+)\] ?/\1 /' | awk 'NR>1{printf "%7.2f  %s\n", $1-p, prev} {p=$1; prev=substr($0,1,110)}' | sort -rn | head -8 | sed 's/^/  +/'
done
echo "---why ldconfig ran (it is on the critical chain)---"
ls -la /etc/.updated /var/.updated 2>&1 | sed 's/^/  /'
systemctl show ldconfig.service -p ConditionResult -p ExecMainStartTimestampMonotonic -p ExecMainExitTimestampMonotonic 2>/dev/null | sed 's/^/  /'
echo "---networking.service (gates network-online, which gates rc.local, which gates getty)---"
grep -vE '^\s*#|^\s*$' /etc/network/interfaces 2>/dev/null | sed 's/^/  /'
journalctl -b -u networking --no-pager -o short-monotonic 2>/dev/null | head -8 | cut -c1-120 | sed 's/^/  /'
systemctl cat rc-local.service 2>/dev/null | grep -E '^(After|Before|Wants)=' | sed 's/^/  rc-local: /'
systemctl cat getty.target 2>/dev/null | grep -E '^(After|Before|Wants)=' | sed 's/^/  getty.target: /'
echo "---font caches (built at first start if absent from the image)---"
ls -la --time-style=+%T /var/cache/fontconfig 2>/dev/null | head -4 | sed 's/^/  /'; ls -la --time-style=+%T /root/.cache/fontconfig 2>/dev/null | head -4 | sed 's/^/  /'
echo "  now: $(date +%T)"
echo "---kernel modules loaded now (initrd ships 360)---"
echo "  $(lsmod | awk 'NR>1' | wc -l) loaded: $(lsmod | awk 'NR>1{print $1}' | sort | tr '\n' ' ')"
echo "===GUI-END==="
echo "===GUI-MARKER==="
RGUI
	chmod +x "$WORK/iso/live/rootcopy/usr/local/bin/rgui"
}

bt_build
bt_boot

echo
echo "== timeline (guest seconds from kernel start; host saw cliexec at ${BT_CLI}s, guiexec at ${BT_GUI:-?}s)"
# Kernel-stamped lines first, then the PROF stamps, in one merged, ordered list.
{
	grep -aE '^\[ *[0-9.]+\] (Linux version|Trying to unpack rootfs|Freeing initrd memory|Run /init)' "$SER.clean" \
		| sed -E 's/^\[ *([0-9.]+)\] (.*)/\1 KERNEL \2/' | cut -c1-90
	grep -a 'PROF [0-9]' "$SER.clean" | sed -E 's/.*PROF ([0-9.]+) /\1 /' | grep -v '^[0-9.]* modprobe '
	grep -aE '^\[ *[0-9.]+\] systemd\[1\]: (Startup finished|Reached target .*(basic|multi-user|graphical))' "$SER.clean" \
		| sed -E 's/^\[ *([0-9.]+)\] systemd\[1\]: (.*)/\1 SYSTEMD \2/'
} | sort -n | awk 'BEGIN{p=0} { d=$1-p; printf "%8.2fs  (+%6.2f)  ", $1, d; $1=""; print substr($0,2); p=$1?$1:p }' 2>/dev/null \
  | awk '{ print }'
if [ "${PROF_FINE:-0}" = 1 ]; then
	echo
	echo "== the modprobe loop, per module (top 20 by time; the last stamp closes the loop)"
	grep -a 'PROF [0-9]' "$SER.clean" | sed -E 's/.*PROF ([0-9.]+) /\1 /' \
	  | awk '/ modprobe / || /modprobe loop done/ { if (m!="") printf "%6.2f  %s\n", $1-t, m; t=$1; m=$2" "$3 }' \
	  | sort -rn | head -20 | sed 's/^/   /'
	N=$(grep -ac 'PROF [0-9.]* modprobe ' "$SER.clean")
	echo "   $N modprobe calls stamped"
fi
echo
sed -n '/===GUI-REPORT===/,/===GUI-END===/p' "$SER.clean"
echo
echo "serial log: $SER.clean"

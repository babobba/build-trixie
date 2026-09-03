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
	# PROF_ROOTCOPY=<dir>: a tree copied over the union at boot through the
	# medium's rootcopy directory, the way the initrd has always offered.
	# This is how a change to the rootfs - a script under /etc, a systemd
	# drop-in - is measured before the hour-long rebuild that ships it.
	if [ -n "${PROF_ROOTCOPY:-}" ]; then
		[ -d "$PROF_ROOTCOPY" ] || bt_fail "PROF_ROOTCOPY=$PROF_ROOTCOPY is not a directory"
		cp -a "$PROF_ROOTCOPY"/. "$WORK/iso/live/rootcopy/"
		# The initrd copies rootcopy with cp -a, which gives /usr the mtime of
		# rootcopy/usr - newer than any update-done stamp the tree carries, so
		# ldconfig would run and the stamp would look broken. Make the stamps
		# the newest thing on the medium.
		for f in etc/.updated var/.updated; do [ -f "$WORK/iso/live/rootcopy/$f" ] && touch "$WORK/iso/live/rootcopy/$f"; done
		echo "   rootcopy: $(cd "$PROF_ROOTCOPY" && find . -type f | sed 's|^\./||' | tr '\n' ' ')"
	fi
	P="$WORK/prof-ird"; rm -rf "$P"; mkdir -p "$P"
	bt_initrd_unpack "$WORK/iso/live/initrd1.xz" "$P" || bt_fail "could not unpack the repacked initrd"
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
		# the base list, one stamp per module, and the modalias passes, with
		# how many aliases each one tried
		sed -i 's/for MODULE in \$(cat modlist); do modprobe \$MODULE 2>\/dev\/null; done/for MODULE in $(cat modlist); do prof "modprobe $MODULE"; modprobe $MODULE 2>\/dev\/null; done; prof "modlist done"/' "$L"
		sed -i 's/^    for M in `cat \/tmp\/modalias.\$1.hit`; do modprobe "\$M" 2>\/dev\/null; done$/    prof "modalias pass $1: $(sed -n \x27$=\x27 \/tmp\/modalias.$1) aliases seen, $(sed -n \x27$=\x27 \/tmp\/modalias.$1.hit) claimed by a driver: $(tr \x27\\n\x27 \x27 \x27 < \/tmp\/modalias.$1.hit)"\n&\n    prof "modalias pass $1 done"/' "$L"
		RC="$WORK/iso/live/rootcopy"; X="$WORK/sqx"; rm -rf "$X"
		unsquashfs -q -f -d "$X" "$ISODATA/live/01-filesystem.squashfs" \
			etc/profile root/.config/openbox/autostart >/dev/null 2>&1 \
			|| bt_fail "could not extract /etc/profile and the autostart from the squashfs"
		GPROF='prof() { read _up _ < /proc/uptime; echo "PROF $_up $*" > /dev/ttyS0; }'
		mkdir -p "$RC/etc" "$RC/root/.config/openbox"
		# A rootcopy that already carries these files is the version under test.
		[ -f "$RC/etc/profile" ] && cp -f "$RC/etc/profile" "$X/etc/profile"
		[ -f "$RC/root/.config/openbox/autostart" ] && cp -f "$RC/root/.config/openbox/autostart" "$X/root/.config/openbox/autostart"
		{ echo "$GPROF"; sed -e 's/^sleep 3$/prof "profile: sleep 3 before startx"; sleep 3/' \
		                     -e 's/^startx$/prof "profile: startx"; startx/' "$X/etc/profile"; } > "$RC/etc/profile"
		{ echo '#!/bin/sh'; echo "$GPROF"; echo 'prof "autostart: begin"'
		  sed -e 's/^pcmanfm --desktop &$/prof "autostart: pcmanfm+lxpanel"; &/' \
		      -e 's/^sleep 8$/prof "autostart: sleep 8"; sleep 8; prof "autostart: after sleep"/' \
		      -e 's/^\(n=0; until xdotool .*\)$/prof "autostart: waiting for the desktop window"; \1; prof "autostart: desktop window is up"/' \
		      -e 's/^volumeicon &$/prof "autostart: volumeicon"; &/' "$X/root/.config/openbox/autostart"
		  echo 'prof "autostart: end of the shipped script"'; } > "$RC/root/.config/openbox/autostart"
		chmod 644 "$RC/etc/profile"; chmod 755 "$RC/root/.config/openbox/autostart"
		# rc.local as well - getty@tty1 waits for it, so its steps are on the
		# path to the login prompt.
		unsquashfs -q -f -d "$X" "$ISODATA/live/01-filesystem.squashfs" etc/rc.local >/dev/null 2>&1
		[ -f "$RC/etc/rc.local" ] && cp -f "$RC/etc/rc.local" "$X/etc/rc.local"
		if [ -f "$X/etc/rc.local" ]; then
			{ sed -n '1p' "$X/etc/rc.local"; echo "$GPROF"; echo 'prof "rc.local: begin"'
			  sed -e '1d' -e 's|^/usr/local/bin/mountlink$|prof "rc.local: mountlink"; &|' \
			      -e 's|^/usr/local/bin/mnt-backing$|prof "rc.local: mnt-backing"; &|' \
			      -e 's|^cat /opt/docs/welcome|prof "rc.local: welcome"; &|' \
			      -e 's|^/usr/local/bin/cowsave$|prof "rc.local: cowsave"; &|' \
			      -e 's|^exit 0$|prof "rc.local: done"; exit 0|' "$X/etc/rc.local"; } > "$RC/etc/rc.local"
			chmod 755 "$RC/etc/rc.local"
		fi
		echo "   fine mode: per-modprobe stamps, stamped /etc/profile and openbox autostart"
	fi
	# PROF_STRACE=1 traces the whole X session - openbox-session and every
	# child - with strace, to attribute time that no script stamp can reach
	# (what openbox itself does between starting and running its autostart).
	# The guest has no strace, so the host's is carried in with the libraries
	# it needs and run from /opt/strace; ~/.xsession is where Debian's Xsession
	# lets a user take over the session, and it is used for exactly that.
	# PROF_STRACE=openbox traces every syscall of the openbox process alone
	# (no children), for the case where the session-wide trace shows it
	# going quiet: the syscall it went quiet in is the answer.
	if [ "${PROF_STRACE:-0}" != 0 ]; then
		command -v strace >/dev/null || bt_fail "PROF_STRACE needs strace on the host"
		RC="$WORK/iso/live/rootcopy"; mkdir -p "$RC/opt/strace" "$RC/root"
		cp -L "$(command -v strace)" "$RC/opt/strace/strace"
		for lib in $(ldd "$(command -v strace)" | awk '/=> \//{print $3}' | grep -v 'libc\.so'); do cp -L "$lib" "$RC/opt/strace/"; done
		if [ "$PROF_STRACE" = openbox ]; then
			cat > "$RC/root/.xsession" <<'XS'
#!/bin/sh
read UP _ < /proc/uptime; echo "PROF $UP xsession: strace (openbox only, all syscalls) starts openbox-session" > /dev/ttyS0
exec env LD_LIBRARY_PATH=/opt/strace /opt/strace/strace -tt -T -o /tmp/openbox.strace openbox-session
XS
		else
			cat > "$RC/root/.xsession" <<'XS'
#!/bin/sh
read UP _ < /proc/uptime; echo "PROF $UP xsession: strace starts openbox-session" > /dev/ttyS0
exec env LD_LIBRARY_PATH=/opt/strace /opt/strace/strace -f -tt -e trace=execve,connect,openat -o /tmp/session.strace openbox-session
XS
		fi
		chmod +x "$RC/root/.xsession"
		# The X server as well, execve only: a client that goes quiet for
		# seconds is usually waiting on the server, and what the server runs
		# (xkbcomp, above all) is the tell. xinit honours ~/.xserverrc.
		cat > "$RC/root/.xserverrc" <<'XSRV'
#!/bin/sh
exec env LD_LIBRARY_PATH=/opt/strace /opt/strace/strace -f -tt -e trace=execve -o /tmp/xorg.strace /usr/bin/X -nolisten tcp "$@"
XSRV
		chmod +x "$RC/root/.xserverrc"
		echo "   strace mode: the X session and the X server run under $(strace -V | head -1)"
	fi
	grep -c '^PROF\|prof ' "$L" >/dev/null || bt_fail "instrumentation did not apply"
	bt_initrd_pack "$P" "$IRD_FMT" > "$WORK/iso/live/initrd1.xz" || bt_fail "could not repack the instrumented initrd"
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
echo "---CPU time consumed so far (TIME) against age (ELAPSED): who has been busy---"
ps -o pid,etimes,times,comm -C Xorg,openbox,pcmanfm,lxpanel,conky,systemd 2>/dev/null | sed 's/^/  /'
# PID 1 split into user and kernel time. Under QEMU a serial console is
# written synchronously, byte by byte, and systemd's status lines are
# many: kernel time dominating here is that, not systemd working.
HZ=$(getconf CLK_TCK); awk -v hz="$HZ" '{ printf "  pid 1: user %.1fs, kernel %.1fs\n", $14/hz, $15/hz }' /proc/1/stat
echo "---X server: first/last log stamp and the 8 biggest gaps inside---"
for f in /var/log/Xorg.0.log /root/.local/share/xorg/Xorg.0.log; do [ -f "$f" ] || continue
	echo "  $f: $(grep -aoE '^\[ *[0-9.]+\]' "$f" | sed -n '1p' | tr -d '[] ') -> $(grep -aoE '^\[ *[0-9.]+\]' "$f" | tail -1 | tr -d '[] ')"
	grep -aE '^\[ *[0-9.]+\]' "$f" | sed -E 's/^\[ *([0-9.]+)\] ?/\1 /' | awk 'NR>1{printf "%7.2f  %s\n", $1-p, prev} {p=$1; prev=substr($0,1,110)}' | sort -rn | head -8 | sed 's/^/  +/'
done
echo "---why ldconfig ran (it is on the critical chain)---"
ls -la /etc/.updated /var/.updated 2>&1 | sed 's/^/  /'
systemctl show ldconfig.service -p ConditionResult -p ExecMainStartTimestampMonotonic -p ExecMainExitTimestampMonotonic 2>/dev/null | sed 's/^/  /'
echo "---networking.service (network.target gates systemd-user-sessions, which gates getty)---"
grep -vE '^\s*#|^\s*$' /etc/network/interfaces /etc/network/interfaces.d/* 2>/dev/null | sed 's/^/  /'
echo "  ifquery lists: '$(ifquery --read-environment --list --exclude=lo 2>/dev/null | tr '\n' ' ')'"
journalctl -b -u ifupdown-pre -u networking --no-pager -o short-monotonic 2>/dev/null | head -12 | cut -c1-140 | sed 's/^/  /'
systemctl show networking.service -p ExecMainStartTimestampMonotonic -p ExecMainExitTimestampMonotonic -p ExecStartPre 2>/dev/null | cut -c1-200 | sed 's/^/  /'
systemctl cat rc-local.service 2>/dev/null | grep -E '^(After|Before|Wants)=' | sed 's/^/  rc-local: /'
systemctl cat getty.target 2>/dev/null | grep -E '^(After|Before|Wants)=' | sed 's/^/  getty.target: /'
echo "---font caches (built at first start if absent from the image)---"
ls -la --time-style=+%T /var/cache/fontconfig 2>/dev/null | head -4 | sed 's/^/  /'; ls -la --time-style=+%T /root/.cache/fontconfig 2>/dev/null | head -4 | sed 's/^/  /'
echo "  now: $(date +%T)"
if [ -s /tmp/openbox.strace ]; then
	echo "---openbox alone, every syscall: the 15 longest gaps and the syscall each was spent in---"
	awk '{ split($2,t,":"); s=t[1]*3600+t[2]*60+t[3]; if (p!="" && s-p>0.2) printf "  +%5.2fs in: %s\n", s-p, substr(prev,1,150); p=s; prev=$0 }' /tmp/openbox.strace | sort -rn | head -15
	echo "  syscalls traced: $(wc -l < /tmp/openbox.strace); nanosleep/clock_nanosleep calls: $(grep -c 'nanosleep' /tmp/openbox.strace); execve: $(grep -c 'execve(' /tmp/openbox.strace)"
	# Where the wall clock went between rc.xml and the autostart: per syscall,
	# count and time inside it (-T), against the window's length. Whatever is
	# left over is user-space CPU.
	awk 'BEGIN{w=0} /openat\(.*rc\.xml/{w=1; split($1,t,":"); t0=t[1]*3600+t[2]*60+t[3]} /execve\(.*openbox-autostart/{ if (w) { split($1,t,":"); t1=t[1]*3600+t[2]*60+t[3] }; w=0 }
	     w { n=$2; sub(/\(.*/,"",n); c[n]++; if (match($0,/<[0-9.]+>$/)) s[n]+=substr($0,RSTART+1,RLENGTH-2) }
	     END { tot=0; for (k in c) { tot+=s[k]; printf "  %6d  %7.2fs  %s\n", c[k], s[k], k }; printf "WINDOW rc.xml -> autostart: %.2fs, of which inside syscalls %.2fs; the rest is user-space CPU\n", t1-t0, tot }' /tmp/openbox.strace > /tmp/ob.summary
	grep '^WINDOW' /tmp/ob.summary | sed 's/^/  /'; grep -v '^WINDOW' /tmp/ob.summary | sort -k2 -rn | head -12
fi
if [ -s /tmp/session.strace ]; then
	echo "---strace of the X session: every execve, then the 12 longest gaps (pid, gap, the line before the gap)---"
	grep -a 'execve(' /tmp/session.strace | grep -v ENOENT | sed -E 's/^([0-9]+) ([0-9:.]+) execve\("([^"]*)".*/  \2 pid \1 \3/' | head -40
	awk '{ split($2,t,":"); s=t[1]*3600+t[2]*60+t[3]; if (p!="" && s-p>0.3) printf "  +%5.2fs pid %s  %s\n", s-p, $1, substr(prev,1,120); p=s; prev=$0 }' /tmp/session.strace | sort -rn | head -12
	# openbox itself, from its execve to the moment it spawns the autostart:
	# what it opened, second by second, and the longest waits inside it.
	if [ -s /tmp/xorg.strace ]; then
		echo "---the X server: every program it ran, with the time each took (strace -f, execve only)---"
		grep -a 'execve(' /tmp/xorg.strace | grep -v ENOENT | sed -E 's/^([0-9]+) +([0-9:.]+) execve\("([^"]*)", \[([^]]*)\].*/\2 pid \1 \3 [\4]/' | cut -c1-150 | sed 's/^/  /' | head -20
		grep -aE 'execve\(|exited with' /tmp/xorg.strace | awk '{ split($2,t,":"); s=t[1]*3600+t[2]*60+t[3]; if ($3 ~ /^execve/) { st[$1]=s; match($0,/execve\("[^"]*"/); nm[$1]=substr($0,RSTART+8,RLENGTH-9) } else if ($1 in st) printf "  %6.2fs  %s (pid %s)\n", s-st[$1], nm[$1], $1 }' | sort -rn | head -8
	fi
	OBPID=$(grep -a 'execve("/usr/bin/openbox"' /tmp/session.strace | head -1 | cut -d' ' -f1)
	ASPID=$(grep -a 'execve("/usr/lib/[^"]*/openbox-autostart"' /tmp/session.strace | head -1 | cut -d' ' -f1)
	if [ -n "$OBPID" ]; then
		echo "---openbox (pid $OBPID) until it spawned the autostart (pid ${ASPID:-?}): opens per second by path prefix---"
		awk -v ob="$OBPID" -v as="$ASPID" '$1==ob { if (index($0,"openbox-autostart")) exit; if ($3 ~ /^openat/) { split($2,t,":"); sec=int(t[1]*3600+t[2]*60+t[3]); match($0,/"[^"]*"/); path=substr($0,RSTART+1,RLENGTH-2); n=split(path,q,"/"); pre=(n>3)?"/"q[2]"/"q[3]"/"q[4]:path; c[sec" "pre]++ } }
		     END { for (k in c) print k, c[k] }' /tmp/session.strace | sort -n | awk '{ if ($1!=last) { if (last!="") print line; line="  "$1"s:"; last=$1 } line=line" "$2"("$3")" } END { print line }' | sed 's/\([0-9]*\)s:/@\1/' | head -30
		echo "---openbox: the 10 longest gaps between its own syscalls in that window---"
		awk -v ob="$OBPID" '$1==ob { if (index($0,"openbox-autostart")) exit; split($2,t,":"); s=t[1]*3600+t[2]*60+t[3]; if (p!="") printf "  +%5.2fs after: %s\n", s-p, substr(prev,7,130); p=s; prev=$0 }' /tmp/session.strace | sort -rn | head -10
	fi
fi
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

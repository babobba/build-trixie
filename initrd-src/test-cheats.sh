#!/bin/sh
# Run the cheatcode block from initrd-src/linuxrc against a fake root and
# assert that each cheatcode writes what it is supposed to write.
set -u
SRC=$(dirname "$0")/linuxrc
WORK=${WORK:-/tmp/cheattest}
PASS=0; FAIL=0

extract_block() {
    awk '/^CHEATRC=\/tmp\/cheatrc/,/^cp -af \/dev\/console/' "$SRC" \
        | grep -v '^cp -af /dev/console' \
        | grep -v '^####'
}

# Build a fake /union that looks like the DebianDog rootfs
make_fakeroot() {
    rm -rf "$WORK"; mkdir -p "$WORK/union/etc/default" "$WORK/union/etc/init.d" \
        "$WORK/union/root/.config/openbox" "$WORK/union/home/puppy/.config/openbox" \
        "$WORK/union/usr/share/zoneinfo/Europe" "$WORK/tmp"
    printf 'XKBMODEL="pc105"\nXKBLAYOUT="us"\nXKBVARIANT=""\n' > "$WORK/union/etc/default/keyboard"
    printf '1:2345:respawn:/bin/login -f root tty6 </dev/tty1 >/dev/tty1 2>&1\n' > "$WORK/union/etc/inittab"
    printf '#!/bin/sh -e\n/usr/local/bin/cowsave\nexit 0\n' > "$WORK/union/etc/rc.local"
    chmod +x "$WORK/union/etc/rc.local"
    printf '#!/bin/sh\n' > "$WORK/union/etc/init.d/hwclock.sh"; chmod +x "$WORK/union/etc/init.d/hwclock.sh"
    printf '#!/bin/sh\n' > "$WORK/union/etc/init.d/bluetooth"; chmod +x "$WORK/union/etc/init.d/bluetooth"
    : > "$WORK/union/usr/share/zoneinfo/Europe/Amsterdam"
    : > "$WORK/union/root/.config/openbox/autostart"
    : > "$WORK/union/home/puppy/.config/openbox/autostart"
}

run_block() {   # $1 = kernel command line
    printf ' %s\n' "$1" > "$WORK/cmdline"
    {
        echo 'i=""'
        echo "param() { egrep -qo \" \$1( |\\\$)\" $WORK/cmdline; }"
        echo "value() { egrep -o \" \$1=[^ ]+\" $WORK/cmdline | cut -d= -f2; }"
        extract_block | sed -e "s#/union#$WORK/union#g" -e "s#/tmp/cheatrc#$WORK/tmp/cheatrc#g" \
                            -e "s#/tmp/rc.local.new#$WORK/tmp/rc.local.new#g"
    } > "$WORK/block.sh"
    sh "$WORK/block.sh" >"$WORK/out" 2>&1
}

check() {   # $1 = description, $2 = file, $3 = grep pattern
    if grep -q -- "$3" "$2" 2>/dev/null; then
        echo "  PASS  $1"; PASS=$((PASS+1))
    else
        echo "  FAIL  $1"; echo "        wanted /$3/ in $2"; sed -n '1,8p' "$2" 2>/dev/null | sed 's/^/        | /'
        FAIL=$((FAIL+1))
    fi
}
checkx() {  # $1 = description, $2 = file must NOT be executable
    if [ -x "$2" ]; then echo "  FAIL  $1"; FAIL=$((FAIL+1))
    else echo "  PASS  $1"; PASS=$((PASS+1)); fi
}

echo "== kmap / timezone / utc =="
make_fakeroot
run_block "quiet kmap=fr timezone=Europe/Amsterdam utc"
check "kmap= sets XKBLAYOUT"        "$WORK/union/etc/default/keyboard" 'XKBLAYOUT="fr"'
check "kmap= leaves XKBMODEL alone" "$WORK/union/etc/default/keyboard" 'XKBMODEL="pc105"'
check "timezone= writes /etc/timezone" "$WORK/union/etc/timezone" 'Europe/Amsterdam'
check "utc writes /etc/adjtime"     "$WORK/union/etc/adjtime" 'UTC'
[ -L "$WORK/union/etc/localtime" ] && { echo "  PASS  timezone= relinks /etc/localtime"; PASS=$((PASS+1)); } \
    || { echo "  FAIL  timezone= relinks /etc/localtime"; FAIL=$((FAIL+1)); }

echo "== bad timezone is rejected =="
make_fakeroot
run_block "quiet timezone=Mars/Olympus"
[ -f "$WORK/union/etc/timezone" ] && { echo "  FAIL  unknown timezone ignored"; FAIL=$((FAIL+1)); } \
    || { echo "  PASS  unknown timezone ignored"; PASS=$((PASS+1)); }

echo "== login= / nologin =="
make_fakeroot; run_block "quiet login=puppy"
check "login= rewrites inittab" "$WORK/union/etc/inittab" 'login -f puppy'
make_fakeroot; run_block "quiet nologin"
check "nologin swaps in getty" "$WORK/union/etc/inittab" 'getty 38400 tty1'

echo "== volume / zram / cliexec into rc.local =="
make_fakeroot
run_block "quiet volume=42% zram=25 cliexec=echo~hello~world;touch~/tmp/flag"
check "volume= writes amixer"          "$WORK/union/etc/rc.local" 'amixer -q set Master 42%'
check "zram= writes disksize setup"    "$WORK/union/etc/rc.local" 'zram0/disksize'
check "zram= uses the given percent"   "$WORK/union/etc/rc.local" '\* 25 / 100'
check "cliexec= expands ~ to spaces"   "$WORK/union/etc/rc.local" 'echo hello world'
check "cliexec= splits on ;"           "$WORK/union/etc/rc.local" 'touch /tmp/flag'
check "existing rc.local body kept"    "$WORK/union/etc/rc.local" 'cowsave'
[ "$(grep -c '^exit 0' "$WORK/union/etc/rc.local")" = 1 ] \
    && { echo "  PASS  rc.local has exactly one exit 0"; PASS=$((PASS+1)); } \
    || { echo "  FAIL  rc.local exit 0 count"; FAIL=$((FAIL+1)); }
[ "$(tail -n1 "$WORK/union/etc/rc.local")" = "exit 0" ] \
    && { echo "  PASS  exit 0 is last line"; PASS=$((PASS+1)); } \
    || { echo "  FAIL  exit 0 is last line"; FAIL=$((FAIL+1)); }

echo "== guiexec =="
make_fakeroot
run_block "quiet guiexec=xterm~-T~hi;leafpad"
check "guiexec= to root autostart"  "$WORK/union/root/.config/openbox/autostart" 'xterm -T hi &'
check "guiexec= to puppy autostart" "$WORK/union/home/puppy/.config/openbox/autostart" 'leafpad &'

echo "== noupdateclock / nobluetooth =="
make_fakeroot; run_block "quiet noupdateclock"
checkx "noupdateclock disables hwclock.sh" "$WORK/union/etc/init.d/hwclock.sh"

echo "== no cheatcodes: nothing is touched =="
make_fakeroot
cp "$WORK/union/etc/rc.local" "$WORK/rc.local.orig"
cp "$WORK/union/etc/inittab" "$WORK/inittab.orig"
cp "$WORK/union/etc/default/keyboard" "$WORK/keyboard.orig"
run_block "quiet from=/ base_only norootcopy"
for f in rc.local:etc/rc.local inittab:etc/inittab keyboard:etc/default/keyboard; do
    n=${f%%:*}; p=${f#*:}
    if cmp -s "$WORK/$n.orig" "$WORK/union/$p"; then echo "  PASS  $p unchanged"; PASS=$((PASS+1));
    else echo "  FAIL  $p was modified with no cheatcodes"; FAIL=$((FAIL+1)); fi
done
[ -s "$WORK/union/root/.config/openbox/autostart" ] \
    && { echo "  FAIL  autostart modified with no cheatcodes"; FAIL=$((FAIL+1)); } \
    || { echo "  PASS  autostart unchanged"; PASS=$((PASS+1)); }

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" = 0 ]

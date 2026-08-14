#!/bin/sh
# pxe : generate a server setup script that serves this live system to other
# machines, using the same cheatcodes the client side already implements.
. "$(dirname "$0")/lib.sh"

PXS="$WORK/union/usr/local/bin/pxe-server"

run_pxe() {   # $1 = cmdline
	printf ' %s\n' "$1" > "$WORK/cmdline"
	{
		echo 'i=""'
		echo "param() { egrep -qo \" \$1( |\\\$)\" $WORK/cmdline; }"
		echo "value() { egrep -o \" \$1=[^ ]+\" $WORK/cmdline | cut -d= -f2; }"
		echo "CHEATRC=$WORK/tmp/cheatrc"; echo ': > $CHEATRC'
		echo 'NFSPATH=`value nfspath`; [ $NFSPATH ] || NFSPATH=/srv/pxe'
		echo 'PTH=/mnt/sr0/live'
		extract_region '^# pxe \(Porteus\): serve this live system' \
		               '^# Everything collected above goes into one script' \
			| sed "s#/union#$WORK/union#g"
	} > "$WORK/pxe.sh"
	mkdir -p "$WORK/tmp"
	sh "$WORK/pxe.sh" > "$WORK/output" 2>&1
}

echo "-- without the cheatcode nothing is generated"
make_fakeroot; run_pxe "quiet from=/"
assert_no_file "no server script"      "$PXS"

echo "-- pxe generates the server script and hooks it in"
make_fakeroot; run_pxe "quiet from=/ pxe"
assert_file "the script is written"        "$PXS"
assert_executable "it is executable"       "$PXS"
assert_grep "it runs at boot"              "$WORK/tmp/cheatrc" '/usr/local/bin/pxe-server'
assert_grep "the user is told"             "$WORK/output" 'PXE services will start'

echo "-- it serves what the client side expects"
assert_grep "clients get ip= pointing at the server" "$PXS" 'ip=:\$SRVIP'
assert_grep "clients get nfspath="                   "$PXS" 'nfspath=\$PXEROOT'
assert_grep "clients get storage= for persistence"   "$PXS" 'storage=\$PXEROOT/storage'
assert_grep "the export root follows nfspath="       "$PXS" '^PXEROOT=/srv/pxe$'

echo "-- nfspath= moves the export root"
make_fakeroot; run_pxe "quiet from=/ pxe nfspath=/export/live"
assert_grep "the script uses the given root" "$PXS" '^PXEROOT=/export/live$'

echo "-- the live tree is bind-mounted, not copied into the RAM overlay"
make_fakeroot; run_pxe "quiet from=/ pxe"
assert_grep "the live dir is bind-mounted" "$PXS" 'mount --bind "\$LIVEDIR" "\$PXEROOT/live"'
assert_not_grep "the squashfs is not copied" "$PXS" 'cp .*squashfs'

echo "-- exports are read-only except the per-client storage"
assert_grep "the tree is exported read-only" "$PXS" '\$PXEROOT \*(ro,'
assert_grep "storage is exported writable"   "$PXS" '\$PXEROOT/storage \*(rw,'

echo "-- DHCP runs in proxy mode so it cannot hijack the network"
assert_grep "proxy mode is used"     "$PXS" 'dhcp-range=\$SRVIP,proxy'
assert_not_grep "no address range is handed out" "$PXS" 'dhcp-range=[0-9]'
assert_grep "dnsmasq DNS is disabled" "$PXS" '^port=0$'

echo "-- missing packages are named rather than half-starting a server"
assert_grep "dnsmasq is checked"    "$PXS" 'command -v dnsmasq'
assert_grep "the nfs server is checked" "$PXS" 'command -v exportfs'
assert_grep "pxelinux is checked"   "$PXS" 'PXELINUX/pxelinux.0'
assert_grep "the user is pointed at the config" "$PXS" 'default-pxe.conf'

echo "-- a build config exists that installs them"
CONF="$REPO/configs-trixie/default-pxe.conf"
assert_file "default-pxe.conf exists" "$CONF"
for p in dnsmasq nfs-kernel-server pxelinux syslinux-common; do
	assert_grep "it installs $p" "$CONF" "$p"
done

finish

#!/bin/sh
# ip= / nfspath= / storage= : the NFS netboot path.
#
# None of the real commands may run here, so mount, modprobe, lsmod, udhcpc
# and ifconfig are shadowed and the test asserts on the mounts that would have
# been issued.
. "$(dirname "$0")/lib.sh"

run_netboot() {   # $1 = cmdline
	printf ' %s\n' "$1" > "$WORK/cmdline"
	{
		echo 'i=""'
		echo "param() { egrep -qo \" \$1( |\\\$)\" $WORK/cmdline; }"
		echo "value() { egrep -o \" \$1=[^ ]+\" $WORK/cmdline | cut -d= -f2; }"
		echo 'mount() { echo "MOUNT $*" >> '"$WORK"'/mounts; }'
		echo 'modprobe() { :; }'
		echo 'udhcpc() { :; }'
		echo 'lspci() { :; }'
		echo 'lsmod() { echo "'"${LSMOD:-nfsv4}"'"; }'
		echo 'ifconfig() { echo "eth0      Link encap:Ethernet  HWaddr 52:54:00:AA:BB:CC"; }'
		echo 'ls() { command ls "$@"; }'
		echo 'mkdir() { command mkdir "$@"; }'
		# variable defaults, then the netboot branch itself
		extract_region '^NFSPATH=' '^MOPT='
		extract_region '^IP=' '^NFSPATH='
		# The branch is cut at the `elif`, so close it to make it runnable.
		extract_region '^if \[ \$IP \]; then BOOTDEV=network' '^elif \[ \$ISO \]'
		echo 'fi'
		echo 'echo "CHANGES=$CHANGES"'
		echo 'echo "STORAGE=$STORAGE"'
		echo 'echo "NFSPATH=$NFSPATH"'
	} > "$WORK/net.sh"
	: > "$WORK/mounts"
	CHANGES=$(printf ' %s\n' "$1" | grep -o ' changes=[^ ]*' | cut -d= -f2)
	CHANGES="$CHANGES" sh "$WORK/net.sh" > "$WORK/output" 2>&1
}

echo "-- defaults are unchanged"
make_fakeroot; run_netboot "quiet ip=:10.0.0.1"
assert_grep "the export root defaults to /srv/pxe" "$WORK/output" '^NFSPATH=/srv/pxe$'
assert_grep "storage defaults below it"            "$WORK/output" '^STORAGE=/srv/pxe/storage$'
assert_grep "the export root is mounted"           "$WORK/mounts" 'MOUNT -t nfs.* 10.0.0.1:/srv/pxe /mnt/nfs'
assert_not_grep "storage is not mounted unasked"   "$WORK/mounts" '/mnt/nfs/storage'

echo "-- storage= moves the client's changes"
make_fakeroot; run_netboot "quiet ip=:10.0.0.1 storage=/export/clients"
assert_grep "storage= is honoured"          "$WORK/output" '^STORAGE=/export/clients$'
assert_grep "it is mounted read-write"      "$WORK/mounts" 'MOUNT -t nfs.* 10.0.0.1:/export/clients /mnt/nfs/storage -o rw,nolock'
assert_grep "the user is told"              "$WORK/output" 'using NFS storage /export/clients'
assert_grep "changes move to the client dir" "$WORK/output" "^CHANGES=/storage/client-AABBCC$"

echo "-- storage follows nfspath= instead of staying at /srv/pxe"
make_fakeroot; run_netboot "quiet ip=:10.0.0.1 nfspath=/export/live changes=/export/live/storage"
assert_grep "storage is derived from nfspath" "$WORK/output" '^STORAGE=/export/live/storage$'
assert_grep "the derived path is mounted"     "$WORK/mounts" '10.0.0.1:/export/live/storage /mnt/nfs/storage'

echo "-- the older changes=<storage path> spelling still works"
make_fakeroot; run_netboot "quiet ip=:10.0.0.1 changes=/srv/pxe/storage"
assert_grep "the legacy trigger still fires" "$WORK/mounts" '10.0.0.1:/srv/pxe/storage /mnt/nfs/storage'
assert_grep "changes move to the client dir" "$WORK/output" '^CHANGES=/storage/client-'

echo "-- nfs3 fallback uses the same path"
make_fakeroot; LSMOD=nfsv3 run_netboot "quiet ip=:10.0.0.1 storage=/export/clients"
assert_grep "nfs3 mounts the same export" "$WORK/mounts" 'MOUNT -t nfs 10.0.0.1:/export/clients /mnt/nfs/storage'

echo "-- a failed storage mount says so instead of silently using memory"
make_fakeroot
printf ' %s\n' "quiet ip=:10.0.0.1 storage=/export/clients" > "$WORK/cmdline"
sed 's#^mount() .*#mount() { echo "MOUNT $*" >> '"$WORK"'/mounts; return 1; }#' "$WORK/net.sh" > "$WORK/netfail.sh"
: > "$WORK/mounts"; CHANGES="" sh "$WORK/netfail.sh" > "$WORK/output" 2>&1
assert_grep "the failure is reported" "$WORK/output" 'could not mount /export/clients'

finish

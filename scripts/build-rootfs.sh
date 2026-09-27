#!/usr/bin/env bash
# Build a firmware-free Debian GNOME arm64 tree. Local image assembly adds hardware inputs.
# Usage: build-rootfs.sh --suite trixie --output DIR [--authorized-keys FILE] [--userspace-dir DIR]
set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin:$PATH
SUITE=trixie OUTDIR='' KEYS='' USERSPACE_DIR=''
die() { echo "build-rootfs: $*" >&2; exit 1; }
while [ $# -gt 0 ]; do
    case "$1" in
        --suite) SUITE=${2:?}; shift 2 ;;
        --output) OUTDIR=${2:?}; shift 2 ;;
        --authorized-keys) KEYS=$(realpath "${2:?}"); shift 2 ;;
        --userspace-dir) USERSPACE_DIR=$(realpath "${2:?}"); shift 2 ;;
        -h|--help) echo 'Usage: build-rootfs.sh --suite trixie --output DIR [--authorized-keys FILE] [--userspace-dir DIR]'; exit 0 ;;
        *) die "unknown option $1" ;;
    esac
done
[ "$SUITE" = trixie ] || die 'this desktop profile supports trixie only'
[ -n "$OUTDIR" ] || die '--output is required'
[ "$(id -u)" = 0 ] || die 'run with sudo (debootstrap and chroot mounts require root)'
for tool in debootstrap chroot curl ssh-keygen openssl mount umount; do
    command -v "$tool" >/dev/null || die "missing $tool"
done
KEYRING=${DEBIAN_ARCHIVE_KEYRING:-/usr/share/keyrings/debian-archive-keyring.gpg}
[ -s "$KEYRING" ] || die 'install debian-archive-keyring or set DEBIAN_ARCHIVE_KEYRING'
[ -z "$KEYS" ] || [ -s "$KEYS" ] || die 'empty authorized keys'
QEMU=
if [ "$(uname -m)" != aarch64 ]; then
    QEMU=$(command -v qemu-aarch64-static) || die 'install qemu-aarch64-static'
    grep -q '^enabled' /proc/sys/fs/binfmt_misc/qemu-aarch64 || die 'enable qemu-aarch64 binfmt first'
fi
REPO=$(cd "$(dirname "$0")/.." && pwd)
OUTDIR=$(realpath -m "$OUTDIR")
[ ! -e "$OUTDIR" ] || die 'output exists; choose a new directory'
curl -fsI --max-time 30 https://deb.debian.org/debian/ >/dev/null
mkdir -p "$OUTDIR/rootfs"
ROOTFS=$OUTDIR/rootfs
# Install the trap before the first mount; never propagate unmounts to the host.
cleanup() {
    for d in dev/pts dev sys proc; do
        if mountpoint -q "$ROOTFS/$d"; then umount "$ROOTFS/$d"; fi
    done
}
trap cleanup EXIT
if [ -z "$KEYS" ]; then
    ssh-keygen -q -t ed25519 -N '' -C piano -f "$OUTDIR/access-key"
    KEYS=$OUTDIR/access-key.pub
fi
debootstrap --arch=arm64 --variant=minbase --components=main --keyring="$KEYRING" --foreign \
    "$SUITE" "$ROOTFS" https://deb.debian.org/debian
[ -z "$QEMU" ] || install -m 0755 "$QEMU" "$ROOTFS/usr/bin/qemu-aarch64-static"
chroot "$ROOTFS" /debootstrap/debootstrap --second-stage
mount -t proc proc "$ROOTFS/proc"
mount --bind /sys "$ROOTFS/sys"
mount --make-slave "$ROOTFS/sys"
mount --bind /dev "$ROOTFS/dev"
mount --make-slave "$ROOTFS/dev"
mount --bind /dev/pts "$ROOTFS/dev/pts"
mount --make-slave "$ROOTFS/dev/pts"
# Suppress service starts and kernel/initramfs hooks inside the build chroot.
printf '#!/bin/sh\nexit 101\n' > "$ROOTFS/usr/sbin/policy-rc.d"
chmod 0755 "$ROOTFS/usr/sbin/policy-rc.d"
cat > "$ROOTFS/etc/apt/sources.list" <<EOF
deb https://deb.debian.org/debian trixie main
deb https://deb.debian.org/debian trixie-updates main
deb https://security.debian.org/debian-security trixie-security main
EOF
# Bootstrap has no CA store yet; install it using the authenticated Debian archive.
printf 'deb http://deb.debian.org/debian trixie main\n' > "$ROOTFS/etc/apt/sources.list.d/bootstrap.list"
chroot "$ROOTFS" apt-get -o Dir::Etc::sourcelist=sources.list.d/bootstrap.list -o Dir::Etc::sourceparts=- update
chroot "$ROOTFS" apt-get -o Dir::Etc::sourcelist=sources.list.d/bootstrap.list -o Dir::Etc::sourceparts=- install -y ca-certificates
rm "$ROOTFS/etc/apt/sources.list.d/bootstrap.list"
mapfile -t PKGS < <(sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' "$REPO/rootfs/packages.txt")
chroot "$ROOTFS" apt-get update
chroot "$ROOTFS" env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${PKGS[@]}"
if [ -n "$USERSPACE_DIR" ]; then
    shopt -s nullglob
    DEBS=("$USERSPACE_DIR"/*.deb)
    [ "${#DEBS[@]}" -gt 0 ] || die 'no userspace debs found'
    mkdir -p "$ROOTFS/tmp/piano-packages"
    cp "${DEBS[@]}" "$ROOTFS/tmp/piano-packages/"
    chroot "$ROOTFS" sh -c 'DEBIAN_FRONTEND=noninteractive apt-get install -y /tmp/piano-packages/*.deb'
    rm -r "$ROOTFS/tmp/piano-packages"
fi
cp -a "$REPO/rootfs/overlay/." "$ROOTFS/"
find "$ROOTFS/usr/lib/piano" "$ROOTFS/usr/local/bin" -type f -exec chmod 0755 {} +
chroot "$ROOTFS" useradd -m -s /bin/bash -G sudo,audio,video,input,render piano
PASSWORD=$(openssl rand -base64 18)
printf 'piano:%s\n' "$PASSWORD" | chroot "$ROOTFS" chpasswd
chroot "$ROOTFS" passwd -l root
(umask 077; printf 'User: piano\nPassword: %s\nGNOME autologin is enabled. SSH uses keys only.\n' "$PASSWORD" > "$OUTDIR/login.txt")
for home in root home/piano; do
    install -d -m 0700 "$ROOTFS/$home/.ssh"
    install -m 0600 "$KEYS" "$ROOTFS/$home/.ssh/authorized_keys"
done
chroot "$ROOTFS" chown -R piano:piano /home/piano
printf 'piano\n' > "$ROOTFS/etc/hostname"
printf '127.0.0.1 localhost\n127.0.1.1 piano\n::1 localhost ip6-localhost\n' > "$ROOTFS/etc/hosts"
printf 'en_US.UTF-8 UTF-8\nzh_CN.UTF-8 UTF-8\n' > "$ROOTFS/etc/locale.gen"
chroot "$ROOTFS" locale-gen
printf 'LANG=en_US.UTF-8\n' > "$ROOTFS/etc/default/locale"
chroot "$ROOTFS" glib-compile-schemas /usr/share/glib-2.0/schemas
chroot "$ROOTFS" systemctl enable NetworkManager ssh bluetooth piano-usb piano-touch piano-radio piano-hostkeys
chroot "$ROOTFS" systemctl set-default graphical.target
ln -sf /usr/lib/systemd/system/gdm3.service "$ROOTFS/etc/systemd/system/display-manager.service"
# Preserve the bootloader display: neither suspend nor blanking is recoverable yet.
chroot "$ROOTFS" systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
rm -f "$ROOTFS/etc/ssh/ssh_host_"* "$ROOTFS/usr/sbin/policy-rc.d"
: > "$ROOTFS/etc/machine-id"
rm -f "$ROOTFS/var/lib/dbus/machine-id"
ln -sf /etc/machine-id "$ROOTFS/var/lib/dbus/machine-id"
rm -f "$ROOTFS/etc/resolv.conf"
ln -s /run/NetworkManager/resolv.conf "$ROOTFS/etc/resolv.conf"
{
    echo "suite=$SUITE arch=arm64 desktop=gnome firmware=not-included"
    # shellcheck disable=SC2016
    chroot "$ROOTFS" dpkg-query -W -f='${Package} ${Version}\n'
} > "$OUTDIR/build-manifest.txt"
chroot "$ROOTFS" apt-get clean
rm -f "$ROOTFS/usr/bin/qemu-aarch64-static"
cleanup
trap - EXIT
touch "$OUTDIR/COMPLETE"
echo "Rootfs: $ROOTFS; credentials: $OUTDIR/login.txt"

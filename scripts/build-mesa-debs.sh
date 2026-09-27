#!/usr/bin/env bash
# build-mesa-debs.sh — rebuild Debian's backported Mesa with the piano patches.
#
# Usage (as root, in a Debian trixie arm64 system or container):
#   scripts/build-mesa-debs.sh OUTPUT_DIR [VERSION]
#
# No released Mesa matches the Adreno 830 of piano on drm/msm: the kernel
# reports chip id 0xffff44050001 (speed bin in the upper half) and only
# Mesa main lists it (upstream commit 2061a5ee, MR !43878). This rebuilds
# the trixie-backports source package with the upstream patches from
# patches/mesa/ (unmodified, Mesa's MIT licence) and a "+piano" version
# suffix, and copies the resulting .debs to OUTPUT_DIR.
set -euo pipefail

OUTPUT=${1:?usage: build-mesa-debs.sh OUTPUT_DIR [VERSION]}
VERSION=${2:-26.1.6-1~bpo13+1}
REPO=$(cd "$(dirname "$0")/.." && pwd)

[ "$(id -u)" = 0 ] || { echo 'build-mesa-debs: run as root' >&2; exit 1; }
[ "$(dpkg --print-architecture)" = arm64 ] || { echo 'build-mesa-debs: arm64 only' >&2; exit 1; }
mkdir -p "$OUTPUT"
OUTPUT=$(realpath "$OUTPUT")

cat > /etc/apt/sources.list.d/piano-backports.list <<'LIST'
deb http://deb.debian.org/debian trixie-backports main
deb-src http://deb.debian.org/debian trixie-backports main
LIST
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends build-essential ca-certificates devscripts dpkg-dev
apt-get build-dep -y -t trixie-backports "mesa=$VERSION"

work=$(mktemp -d)
cd "$work"
apt-get source -t trixie-backports "mesa=$VERSION"
cd mesa-*/
for patch in "$REPO"/patches/mesa/*.patch; do
    cp "$patch" debian/patches/
    basename "$patch" >> debian/patches/series
done
DEBFULLNAME='piano-linux' DEBEMAIL='piano@localhost' \
    dch --local +piano --distribution trixie-backports \
    'Recognise the Adreno 830 of the Xiaomi Pad 8 Pro on drm/msm (Mesa 2061a5ee).'
dpkg-buildpackage -b -uc -us -j"$(nproc)"
cp ../*.deb "$OUTPUT/"
(cd "$OUTPUT" && sha256sum ./*.deb > SHA256SUMS)
echo "build-mesa-debs: $(find "$OUTPUT" -name "*.deb" | wc -l) packages in $OUTPUT"

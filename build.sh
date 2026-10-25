#!/bin/bash
# Build patched RunCloud-compatible PHP for one Ubuntu release, rootless.
#
# usage: ./build.sh <codename> [rc-tag ...]
#   ./build.sh focal          build every version listed for focal in matrix.tsv
#   ./build.sh xenial 56 74   build only php56rc and php74rc for xenial
#
# Output: out/phpXXrc-<version>[-php2shell]-<codename>.tar.gz
# Work dir (root filesystems, downloads): work/ (several GB per release)
set -euo pipefail
cd "$(dirname "$(realpath "$0")")"
TOP=$PWD
DIST=${1:?usage: ./build.sh <xenial|bionic|focal|jammy|noble> [rc-tag ...]}; shift
WANT=" $* "

case $DIST in
  xenial) UBASE=16.04; UREL=16.04.6 ;;
  bionic) UBASE=18.04; UREL=18.04.5 ;;
  focal)  UBASE=20.04; UREL=20.04.5 ;;
  jammy)  UBASE=22.04; UREL=22.04.5 ;;
  noble)  UBASE=24.04; UREL=24.04.5 ;;
  *) echo "unknown codename: $DIST"; exit 1 ;;
esac

unshare --help 2>/dev/null | grep -q -- --map-users && command -v newuidmap >/dev/null || {
  echo "Needs unshare with --map-users (util-linux 2.38 or newer) and newuidmap (package uidmap)."; exit 1; }
grep -q "^$(id -un):" /etc/subuid && grep -q "^$(id -un):" /etc/subgid || {
  echo "Your user needs a range in /etc/subuid and /etc/subgid (see README)."; exit 1; }

W=$TOP/work; DL=$W/downloads; R=$W/rootfs-$DIST
mkdir -p "$DL" "$TOP/out"

fetch() {  # fetch <url> <file>  and check it against sources.sha256
  local url=$1 f=$2
  if [ ! -f "$DL/$f" ]; then
    curl -fsSL -o "$DL/$f.part" "$url"
    mv "$DL/$f.part" "$DL/$f"
  fi
  local want; want=$(awk -v f="$f" '$2==f{print $1}' "$TOP/sources.sha256")
  [ -n "$want" ] || { echo "no checksum for $f in sources.sha256"; exit 1; }
  echo "$want  $DL/$f" | sha256sum -c --quiet || { echo "CHECKSUM MISMATCH: $f"; exit 1; }
}

# 1) Ubuntu root filesystem
UB=ubuntu-base-$UREL-base-amd64.tar.gz
fetch "https://cdimage.ubuntu.com/ubuntu-base/releases/$UBASE/release/$UB" "$UB"
if [ ! -f "$R/etc/os-release" ]; then
  mkdir -p "$R"
  # device nodes cannot be created rootless; /dev is bind-mounted later
  unshare --user --map-root-user --map-users=auto --map-groups=auto \
    tar -xzf "$DL/$UB" -C "$R" --exclude='./dev/*' 2>/dev/null || true
fi
mkdir -p "$R/src/debs" "$R/src/out"

# 2) RunCloud support packages, verified against the SHA256 in RunCloud's own index
case $DIST in
  xenial|bionic|focal) RCPKGS="libargon2-1 libargon2-1-dev" ;;
  jammy) RCPKGS="libssl1-rc" ;;
  noble) RCPKGS="" ;;
esac
if [ -n "$RCPKGS" ]; then
  IDX=$(curl -fsSL "https://release.runcloud.io/dists/$DIST/main/binary-amd64/Packages.gz" | zcat)
  for p in $RCPKGS; do
    read -r ver fn sum < <(echo "$IDX" | awk -v P="$p" '$0=="Package: "P{f=1} f&&/^Version:/{v=$2}
      f&&/^Filename:/{fn=$2} f&&/^SHA256:/{s=$2} f&&/^$/{print v, fn, s; f=0}' | sort -V | tail -1)
    [ -n "${fn:-}" ] || { echo "package $p not found in release.runcloud.io/$DIST"; exit 1; }
    deb=$(basename "$fn")
    [ -f "$R/src/debs/$deb" ] || curl -fsSL -o "$R/src/debs/$deb" "https://release.runcloud.io/$fn"
    echo "$sum  $R/src/debs/$deb" | sha256sum -c --quiet || { echo "CHECKSUM MISMATCH: $deb"; exit 1; }
    echo "runcloud: $p $ver"
  done
fi

# 3) scripts, configure commands, patches
cp scripts/chroot-deps.sh scripts/chroot-build.sh "$R/src/"
cp configure/configure-php*rc-"$DIST".txt "$R/src/"
cp patches/*.patch "$R/src/"

# 4) build each matrix row for this codename
grep -v '^#' matrix.tsv | while IFS=$'\t' read -r d tag ver patch; do
  [ "$d" = "$DIST" ] || continue
  [ "$WANT" = "  " ] || [[ "$WANT" == *" $tag "* ]] || continue
  echo "=== $DIST php${tag}rc $ver (patch: $patch)"
  fetch "https://www.php.net/distributions/php-$ver.tar.xz" "php-$ver.tar.xz"
  cp "$DL/php-$ver.tar.xz" "$R/src/"
  [ "$patch" = none ] || grep -q " $patch\$" sources.sha256
  scripts/enter.sh "$R" /src/chroot-deps.sh "$DIST" "$tag"
  scripts/enter.sh "$R" /src/chroot-build.sh "$ver" "$tag" "$patch" "$DIST"
  mv "$R"/src/out/php"${tag}"rc-"$ver"-*"$DIST".tar.gz "$TOP/out/"
done
( cd out && sha256sum -- *.tar.gz > SHA256SUMS )
echo "done: $(ls out/*-"$DIST".tar.gz | wc -l) tarball(s) for $DIST in out/"

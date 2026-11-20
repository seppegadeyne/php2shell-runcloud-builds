#!/bin/bash
# Runs INSIDE the chroot. Unpacks the php.net tarball, applies the patches,
# configures with RunCloud's own flags, builds and stages a tarball.
# usage: /src/chroot-build.sh <full-version> <rc-tag> <patch[,patch...]|none> <codename>
# Patches are applied in the given order (php2shell first, then phpaftershell).
set -euo pipefail
FV=$1; TAG=$2; PATCHES=$3; DIST=$4
cd /root && rm -rf "php-$FV" && tar -xJf "/src/php-$FV.tar.xz" && cd "php-$FV"

SUFFIX=
if [ "$PATCHES" != none ]; then
  IFS=, read -r -a PLIST <<< "$PATCHES"
  for PATCH in "${PLIST[@]}"; do
    if ! patch -p1 --dry-run < "/src/$PATCH" > "/root/patch$TAG.log" 2>&1; then
      echo "PATCH FAILED: $PATCH"; grep -E "FAILED|can't find|Hunk" "/root/patch$TAG.log" | head -20; exit 2
    fi
    if grep -q fuzz "/root/patch$TAG.log"; then echo "PATCH NEEDS FUZZ, refusing: $PATCH"; exit 2; fi
    patch -p1 < "/src/$PATCH" >/dev/null
    echo "patch applied: $PATCH ($(grep -c offset "/root/patch$TAG.log" || true) hunks with a line offset, no fuzz)"
    # php-7.4-php2shell.patch -> php2shell-
    n=${PATCH#php-*-}; SUFFIX="$SUFFIX${n%.patch}-"
  done
fi

eval "$(cat "/src/configure-php${TAG}rc-$DIST.txt")" > "/root/configure$TAG.log" 2>&1 \
  || { tail -20 "/root/configure$TAG.log"; exit 1; }
make -j"$(nproc)" > "/root/make$TAG.log" 2>&1 \
  || { grep -m5 -E "error" "/root/make$TAG.log"; tail -15 "/root/make$TAG.log"; exit 1; }
rm -rf "/stage$TAG" && make install INSTALL_ROOT="/stage$TAG" > "/root/install$TAG.log" 2>&1
P="/stage$TAG/RunCloud/Packages/php${TAG}rc"
strip --strip-unneeded "$P/bin/php" "$P/sbin/php-fpm"
echo "BUILD_OK $("$P/bin/php" -n -v | head -1)"

mkdir -p /src/out
cd "/stage$TAG" && tar -czf "/src/out/php${TAG}rc-$FV-${SUFFIX}$DIST.tar.gz" RunCloud
echo "OUT php${TAG}rc-$FV-${SUFFIX}$DIST.tar.gz"

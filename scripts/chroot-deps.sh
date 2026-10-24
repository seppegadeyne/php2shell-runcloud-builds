#!/bin/bash
# Runs INSIDE the chroot. Installs the build dependencies for one Ubuntu release.
# usage: /src/chroot-deps.sh <codename> <rc-tag, e.g. 74>
#
# libargon2 matters: RunCloud links --with-password-argon2 against different
# libargon2 sonames per release, and the patched binary must link the same one.
#   xenial, focal          RunCloud libargon2-1 (libargon2.so.1)
#   bionic, PHP 7.2-8.0    RunCloud libargon2-1 (libargon2.so.1)
#   bionic, PHP 8.1+       Ubuntu libargon2-0  (libargon2.so.0)
#   jammy, noble           Ubuntu libargon2-1  (libargon2.so.1)
# jammy PHP 7.4/8.0 also link RunCloud's own OpenSSL 1.1.1b (libssl1-rc).
set -euo pipefail
DIST=$1; TAG=$2

COMMON="build-essential autoconf bison re2c pkg-config ca-certificates curl xz-utils patch file
  libxml2-dev libssl-dev libsqlite3-dev zlib1g-dev libcurl4-openssl-dev libgmp-dev libffi-dev
  libsystemd-dev libedit-dev libicu-dev libpcre3-dev"
case $DIST in
  xenial) EXTRA="libenchant-dev libselinux1-dev libfcgi0ldbl" ;;
  bionic) EXTRA="libenchant-dev libfcgi0ldbl" ;;
  focal)  EXTRA="libenchant-dev libfcgi0ldbl libfcgi-bin" ;;
  jammy|noble) EXTRA="libenchant-2-dev libfcgi-bin" ;;
  *) echo "unknown codename $DIST"; exit 1 ;;
esac

if [ ! -f /root/.deps-base-done ]; then
  apt-get update -qq
  # shellcheck disable=SC2086
  apt-get install -y -qq --no-install-recommends $COMMON $EXTRA > /root/apt.log 2>&1 \
    || { tail -20 /root/apt.log; exit 1; }
  # PHP 5.6's configure only looks for gmp.h in /usr/include
  ln -sf /usr/include/x86_64-linux-gnu/gmp.h /usr/include/gmp.h
  touch /root/.deps-base-done
fi

rc_argon2() {
  dpkg -r libargon2-0-dev >/dev/null 2>&1 || true
  dpkg -i /src/debs/libargon2-1_*.deb /src/debs/libargon2-1-dev_*.deb >/dev/null
}
case $DIST in
  xenial|focal) rc_argon2 ;;
  bionic)
    if [ "$TAG" -lt 81 ]; then rc_argon2
    else
      dpkg -r libargon2-1-dev >/dev/null 2>&1 || true
      apt-get install -y -qq libargon2-0-dev >/dev/null
    fi ;;
  jammy)
    apt-get install -y -qq libargon2-dev >/dev/null
    dpkg -s libssl1-rc >/dev/null 2>&1 || dpkg -i /src/debs/libssl1-rc_*.deb >/dev/null ;;
  noble)
    apt-get install -y -qq libargon2-dev >/dev/null ;;
esac
echo "DEPS_OK $DIST $(gcc -dumpfullversion -dumpversion)"

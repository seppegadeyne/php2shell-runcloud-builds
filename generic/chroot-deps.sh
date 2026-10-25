#!/bin/bash
# Runs INSIDE the chroot (generic mode). Installs what is needed to build PHP with a server's
# own configure command: the build dependencies of the release's own PHP source package plus
# the libraries that configure flags commonly ask for.
# usage: /src/chroot-deps.sh <codename>
set -euo pipefail
DIST=$1
[ -f /root/.generic-deps-done ] && { echo "DEPS_OK (cached)"; exit 0; }

case $DIST in
  xenial) PHPSRC=php7.0 ;;
  bionic) PHPSRC=php7.2 ;;
  focal)  PHPSRC=php7.4 ;;
  jammy)  PHPSRC=php8.1 ;;
  noble)  PHPSRC=php8.3 ;;
  *) echo "unknown codename $DIST"; exit 1 ;;
esac

# deb-src next to every deb line, so apt-get build-dep works (one-line format up to 22.04,
# deb822 ubuntu.sources from 24.04)
if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
  sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/ubuntu.sources
else
  sed -n 's/^deb /deb-src /p' /etc/apt/sources.list > /etc/apt/sources.list.d/php2shell-src.list
fi
apt-get update -qq

BASE="build-essential autoconf bison re2c pkg-config ca-certificates curl xz-utils patch file"
# libraries configure flags ask for; a name missing in this release is skipped
WANT="libxml2-dev libssl-dev libsqlite3-dev zlib1g-dev libcurl4-openssl-dev libgmp-dev libffi-dev
  libsystemd-dev libedit-dev libreadline-dev libicu-dev libpcre3-dev libpcre2-dev libonig-dev libzip-dev
  libbz2-dev libpng-dev libjpeg-dev libwebp-dev libfreetype6-dev libxpm-dev libavif-dev libgd-dev
  libxslt1-dev libtidy-dev libsodium-dev libargon2-dev libargon2-0-dev libldap2-dev libsasl2-dev
  libpq-dev libsnmp-dev libkrb5-dev libc-client2007e-dev libenchant-dev libenchant-2-dev libpspell-dev
  libaspell-dev librecode-dev libmcrypt-dev libqdbm-dev libgdbm-dev libdb-dev liblmdb-dev libtokyocabinet-dev
  libmm-dev libapparmor-dev libselinux1-dev libfcgi-dev libfcgi0ldbl libfcgi-bin libexpat1-dev
  libgettextpo-dev libltdl-dev libkrb5-dev unixodbc-dev firebird-dev freetds-dev libmagic-dev"

# shellcheck disable=SC2086
apt-get install -y -qq --no-install-recommends $BASE > /root/apt-generic.log 2>&1 || { tail -20 /root/apt-generic.log; exit 1; }
apt-get build-dep -y -qq "$PHPSRC" >> /root/apt-generic.log 2>&1 || echo "note: build-dep $PHPSRC failed, continuing with the list"
avail=""
for p in $WANT; do
  apt-cache show "$p" >/dev/null 2>&1 && avail="$avail $p"
done
# install one by one when the batch conflicts (libargon2-0-dev vs libargon2-dev, enchant 1 vs 2)
# shellcheck disable=SC2086
if ! apt-get install -y -qq --no-install-recommends $avail >> /root/apt-generic.log 2>&1; then
  for p in $avail; do apt-get install -y -qq --no-install-recommends "$p" >> /root/apt-generic.log 2>&1 || true; done
fi
# PHP 5.6's configure only looks for gmp.h in /usr/include
[ -f /usr/include/x86_64-linux-gnu/gmp.h ] && ln -sf /usr/include/x86_64-linux-gnu/gmp.h /usr/include/gmp.h
touch /root/.generic-deps-done
echo "DEPS_OK $DIST $(gcc -dumpfullversion -dumpversion)"

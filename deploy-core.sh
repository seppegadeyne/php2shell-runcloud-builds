#!/bin/bash
# Swap only the patched core of a RunCloud PHP package, keep a way back.
# Run as root on the server.
#
#   bash deploy-core.sh <rc-tag> <tarball>            deploy, e.g. 74 php74rc-7.4.33-php2shell-focal.tar.gz
#   bash deploy-core.sh <rc-tag> <tarball> rollback   restore the original files
#
# Replaces bin/php, sbin/php-fpm and the shared extensions built from the PHP core
# (mysqlnd, pdo, xml, xmlreader, xmlwriter, readline) in /RunCloud/Packages/phpXXrc.
# RunCloud's other extensions and all conf.d files stay untouched.
# The originals are copied once to /root/phpXXrc-orig-before-php2shell/.
# The package is put on apt hold so RunCloud does not reinstall the unpatched build.
set -euo pipefail
V=${1:?usage: deploy-core.sh <rc-tag> <tarball> [rollback]}
TB=${2:?usage: deploy-core.sh <rc-tag> <tarball> [rollback]}
MODE=${3:-deploy}
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
P=/RunCloud/Packages/php${V}rc
[ -x "$P/bin/php" ] || { echo "$P is not installed"; exit 1; }
EXTDIR=$(ls -d "$P"/lib/php/extensions/no-debug-non-zts-*)
BK=/root/php${V}rc-orig-before-php2shell
FILES="bin/php sbin/php-fpm"
CORE_EXT="mysqlnd.so pdo.so xml.so xmlreader.so xmlwriter.so readline.so"

restart_if_active() {
  if systemctl is-active --quiet "php${V}rc-fpm"; then
    "$P/sbin/php-fpm" -t -y "/etc/php${V}rc/php-fpm.conf"
    systemctl restart "php${V}rc-fpm"
  fi
}

if [ "$MODE" = rollback ]; then
  [ -d "$BK" ] || { echo "no backup in $BK"; exit 1; }
  for f in $FILES; do cp -a "$BK/$f" "$P/$f"; done
  for e in $CORE_EXT; do [ -f "$BK/ext/$e" ] && cp -a "$BK/ext/$e" "$EXTDIR/$e"; done
  apt-mark unhold "php${V}rc" >/dev/null
  restart_if_active
  echo "ROLLBACK OK: $("$P/bin/php" -v | head -1)"; exit 0
fi

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
tar -xzf "$TB" -C "$T"
N=$T/RunCloud/Packages/php${V}rc
[ -x "$N/bin/php" ] || { echo "tarball does not contain php${V}rc"; exit 1; }
NEWEXT=$(ls -d "$N"/lib/php/extensions/no-debug-non-zts-*)
[ "$(basename "$NEWEXT")" = "$(basename "$EXTDIR")" ] || { echo "ABORT: extension API mismatch"; exit 1; }

# 1) back up the originals once, never overwrite them
if [ ! -d "$BK" ]; then
  mkdir -p "$BK/bin" "$BK/sbin" "$BK/ext"
  for f in $FILES; do cp -a "$P/$f" "$BK/$f"; done
  for e in $CORE_EXT; do [ -f "$EXTDIR/$e" ] && cp -a "$EXTDIR/$e" "$BK/ext/$e"; done
fi

# 2) the new binary must start cleanly with the real php.ini and extensions
"$N/bin/php" -c "/etc/php${V}rc/php.ini" -m >/dev/null 2>"$T/err" || true
if grep -qi warning "$T/err"; then cat "$T/err"; echo "ABORT: startup warnings"; exit 1; fi

# 3) swap by rename, so running processes keep their old inode
for f in $FILES; do install -m 755 "$N/$f" "$P/$f.new" && mv -f "$P/$f.new" "$P/$f"; done
for e in $CORE_EXT; do
  [ -f "$NEWEXT/$e" ] && install -m 755 "$NEWEXT/$e" "$EXTDIR/$e.new" && mv -f "$EXTDIR/$e.new" "$EXTDIR/$e"
done

# 4) stop RunCloud from putting the unpatched package back
apt-mark hold "php${V}rc" >/dev/null

# 5) service inactive (no pools)? sanity-check the binaries, do not start it
if ! systemctl is-active --quiet "php${V}rc-fpm"; then
  if "$P/sbin/php-fpm" -n -v >/dev/null && "$P/bin/php" -m >/dev/null; then
    echo "DEPLOY OK (service inactive, not started): $("$P/bin/php" -v | head -1)"; exit 0
  fi
  echo "BINARY CHECK FAILED -> rollback"; exec bash "$0" "$V" "$TB" rollback
fi

# 6) config test, restart (a new binary needs a restart, not a reload), roll back on failure
"$P/sbin/php-fpm" -t -y "/etc/php${V}rc/php-fpm.conf" || { echo "CONFIG TEST FAILED -> rollback"; exec bash "$0" "$V" "$TB" rollback; }
systemctl restart "php${V}rc-fpm"; sleep 2
systemctl is-active --quiet "php${V}rc-fpm" || { echo "FPM DID NOT START -> rollback"; exec bash "$0" "$V" "$TB" rollback; }
echo "DEPLOY OK: $("$P/bin/php" -v | head -1) | held: php${V}rc"

#!/bin/bash
# Runs INSIDE the chroot (generic mode). Builds one PHP with the server's own configure command.
# usage: /src/chroot-build.sh <full-version> <patch-file|none> <job-id>
#   /src/<job-id>/configure.txt   the server's configure command (php -i, "Configure Command")
#   /src/<job-id>/want-opcache    present when the server has a shared opcache.so this build must replace
# Result: /stage-<job-id>/ (make install INSTALL_ROOT) and /src/<job-id>/build-info.txt
set -euo pipefail
FV=$1; PATCH=$2; JOB=$3
J=/src/$JOB; S=/stage-$JOB
cd /root && rm -rf "php-$FV-$JOB" && mkdir "php-$FV-$JOB" && tar -xJf "/src/php-$FV.tar.xz" -C "php-$FV-$JOB" --strip-components=1
cd "php-$FV-$JOB"

if [ "$PATCH" != none ]; then
  if ! patch -p1 --dry-run < "/src/$PATCH" > "$J/patch.log" 2>&1; then
    echo "PATCH FAILED:"; grep -E "FAILED|can't find|Hunk" "$J/patch.log" | head -20; exit 2
  fi
  if grep -q fuzz "$J/patch.log"; then echo "PATCH NEEDS FUZZ, refusing"; exit 2; fi
  patch -p1 < "/src/$PATCH" >/dev/null
  echo "patch applied: $PATCH"
fi
# a patched configure.ac (5.6-7.3 ports) needs a fresh configure script
grep -q "configure.ac\|configure.in" "/src/$PATCH" 2>/dev/null && ./buildconf --force >/dev/null 2>&1 || true

# the server's command, verbatim. It starts with './configure' and quotes every argument.
eval "$(cat "$J/configure.txt")" > "$J/configure.log" 2>&1 \
  || { echo "CONFIGURE FAILED (last lines of config.log):"; tail -25 config.log; exit 1; }
make -j"$(nproc)" > "$J/make.log" 2>&1 \
  || { grep -m5 -E "error" "$J/make.log"; tail -15 "$J/make.log"; exit 1; }
rm -rf "$S" && make install INSTALL_ROOT="$S" > "$J/install.log" 2>&1 \
  || { tail -15 "$J/install.log"; exit 1; }

# the extension directory inside the staged tree
PHPCONFIG=$(find "$S" -path '*/bin/php-config*' -type f | head -1)
EXTDIR=$(sed -n "s/^extension_dir=['\"]\{0,1\}\([^'\"]*\).*/\1/p" "$PHPCONFIG" | head -1)

# PHP 8.1: the fix also changes ext/opcache. The server loads a shared opcache.so; the build must
# produce one from this patched tree, or the old, unpatched opcache.so would stay in use.
if [ -f "$J/want-opcache" ] && [ ! -f "$S$EXTDIR/opcache.so" ]; then
  echo "ABORT: the server has a shared opcache.so but this configure command builds none."
  echo "Add --enable-opcache=shared to $J/configure.txt (the server's opcache.so comes from elsewhere)."
  exit 1
fi

# strip and describe every SAPI binary in the staged tree
: > "$J/build-info.txt"
while read -r f; do
  file -b "$f" | grep -q ELF || continue
  strip --strip-unneeded "$f" 2>/dev/null || true
  rel=${f#"$S"}
  echo "binary=$rel" >> "$J/build-info.txt"
  # built-in modules per binary (FPM and CGI add their own SAPI module, so compare like with like)
  "$f" -n -m > "$J/builtin-$(basename "$f").txt" 2>/dev/null || true
done < <(find "$S" -type f \( -path '*/bin/php*' -o -path '*/sbin/php-fpm*' -o -path '*/bin/php-cgi*' \) ! -name 'php-config*' ! -name 'phpize*' ! -name 'phpdbg*')
find "$S$EXTDIR" -maxdepth 1 -name '*.so' -printf 'ext=%f\n' >> "$J/build-info.txt" 2>/dev/null || true
echo "extension_dir=$EXTDIR" >> "$J/build-info.txt"
CLI=$(find "$S" -type f -path '*/bin/php*' ! -name 'php-c*' ! -name 'phpize*' ! -name 'phpdbg*' | head -1)
if [ -n "$CLI" ]; then
  # read the whole output (an early exit makes php die of SIGPIPE under pipefail)
  "$CLI" -n -i > "$J/phpinfo.txt"
  awk -F' => ' '/^PHP Extension =>/ && !m {print "modapi="$2; m=1} /^PHP Extension Build/ && !b {print "buildid="$2; b=1}
    /^PHP Version/ && !v {print "version="$2; v=1}' "$J/phpinfo.txt" >> "$J/build-info.txt"
  "$CLI" -n -m > "$J/builtin-modules.txt"
fi
echo "BUILD_OK $JOB PHP $FV"

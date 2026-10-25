#!/bin/bash
# Generic mode, step 1: record how the PHP on THIS server was built. Read-only.
# Run on the server (root is best, so package ownership and every binary can be read).
#
#   bash collect.sh                       find every PHP CLI / FPM / CGI binary
#   bash collect.sh /usr/sbin/php-fpm7.4  record only the binaries you name
#
# Output: php2shell-profile-<host>-<date>.tar.gz in the current directory.
# Copy it to the build machine and run generic/build.sh on it.
#
# Per binary it records: version, SAPI, the configure command (from -i), extension dir,
# module API number, php.ini paths, linked libraries and the owning package. Per server:
# /etc/os-release and the shared extensions with their owners. Nothing is changed.
set -uo pipefail
export LC_ALL=C

HOST=$(hostname -s 2>/dev/null || hostname)
OUT=php2shell-profile-$HOST-$(date +%Y%m%d-%H%M%S)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
P=$T/$OUT; mkdir -p "$P/bin"

# --- candidates -----------------------------------------------------------------------------
if [ $# -gt 0 ]; then
  CANDS=("$@")
else
  shopt -s nullglob
  CANDS=(/usr/bin/php /usr/bin/php[0-9]* /usr/bin/php-cgi* /usr/sbin/php-fpm*
         /usr/local/bin/php /usr/local/bin/php-cgi /usr/local/sbin/php-fpm
         /opt/*/bin/php /opt/*/sbin/php-fpm /opt/*/*/bin/php /opt/*/*/sbin/php-fpm
         /opt/remi/*/root/usr/bin/php /opt/remi/*/root/usr/sbin/php-fpm
         /RunCloud/Packages/php*rc/bin/php /RunCloud/Packages/php*rc/sbin/php-fpm
         /usr/local/lsws/lsphp*/bin/php /usr/local/lsws/lsphp*/bin/lsphp
         /opt/cpanel/ea-php*/root/usr/bin/php /opt/cpanel/ea-php*/root/usr/sbin/php-fpm
         /opt/plesk/php/*/bin/php /opt/plesk/php/*/sbin/php-fpm)
  shopt -u nullglob
fi

phpinfo() {  # phpinfo() as "Key => Value" lines; php-cgi prints HTML, so turn its table rows into text
  local out
  out=$("$@" 2>/dev/null) || return 1
  if printf '%s' "$out" | grep -q '<tr>'; then
    printf '%s\n' "$out" | grep '<tr>' | sed -E -e 's#</td><td[^>]*>#\t#g' -e 's#<[^>]*>##g' \
      -e "s/&#039;/'/g; s/&quot;/\"/g; s/&lt;/</g; s/&gt;/>/g; s/&amp;/\\&/g" \
      | awk -F'\t' '{for(i=1;i<=NF;i++){sub(/^ +/,"",$i); sub(/ +$/,"",$i)} s=$1; for(i=2;i<=NF;i++) s=s" => "$i; print s}'
  else
    printf '%s\n' "$out"
  fi
}

owner() {  # owning package of a file, or "-"
  local f=$1 o=""
  if command -v dpkg-query >/dev/null 2>&1; then o=$(dpkg-query -S "$f" 2>/dev/null | head -1 | cut -d: -f1)
  elif command -v rpm >/dev/null 2>&1; then o=$(rpm -qf "$f" 2>/dev/null | grep -v 'not owned' | head -1); fi
  echo "${o:--}"
}

# --- server ---------------------------------------------------------------------------------
cp /etc/os-release "$P/os-release" 2>/dev/null || echo "ID=unknown" > "$P/os-release"
{ echo "host=$HOST"; echo "date=$(date -Is)"; echo "kernel=$(uname -r)"; echo "arch=$(uname -m)"
  command -v ldd >/dev/null && echo "glibc=$(ldd --version 2>/dev/null | head -1)"; } > "$P/server.txt"
command -v systemctl >/dev/null 2>&1 && systemctl list-units --type=service --all --no-legend --plain 2>/dev/null \
  | awk '{print $1}' | grep -i php > "$P/services.txt" || true
: > "$P/binaries.tsv"

declare -A SEEN
n=0
for b in "${CANDS[@]}"; do
  [ -f "$b" ] && [ -x "$b" ] || continue
  r=$(readlink -f "$b")
  [ -n "${SEEN[$r]:-}" ] && continue
  SEEN[$r]=1
  # anything that is not a PHP SAPI binary: skip quietly
  case $(basename "$r") in *.so|*.sh|phpize*|php-config*|phpdbg*) continue ;; esac
  info=$(phpinfo "$r" -n -i) || info=$(phpinfo "$r" -i) || continue
  echo "$info" | grep -q '^PHP Version' || continue
  ver=$(echo "$info" | awk -F' => ' '/^PHP Version/{print $2; exit}')
  sapi=$(echo "$info" | awk -F' => ' '/^Server API/{print $2; exit}')
  # only CLI, FPM and CGI can be rebuilt; LiteSpeed's lsphp (SAPI "LiteSpeed") cannot: say so
  case $sapi in
    *Command*|*FPM*|*CGI*) ;;
    *) echo "$r ($ver, $sapi)" >> "$P/unsupported.txt"
       echo "NOTE: $r is PHP $ver with SAPI '$sapi': generic mode rebuilds CLI, FPM and CGI only; patch it another way."
       continue ;;
  esac
  n=$((n+1)); id=b$n; d=$P/bin/$id; mkdir -p "$d"
  api=$(echo "$info" | awk -F' => ' '/^PHP API/{print $2; exit}')
  modapi=$(echo "$info" | awk -F' => ' '/^PHP Extension =>/{print $2; exit}')
  zendapi=$(echo "$info" | awk -F' => ' '/^Zend Extension =>/{print $2; exit}')
  build=$(echo "$info" | awk -F' => ' '/^PHP Extension Build/{print $2; exit}')
  # the real ini settings (not -n): run again without -n for paths and extension_dir
  full=$(phpinfo "$r" -i || echo "$info")
  extdir=$(echo "$full" | awk -F' => ' '/^extension_dir/{print $2; exit}')
  # the compiled-in default (from -n) when the real run gave none
  [ -n "$extdir" ] || extdir=$(echo "$info" | awk -F' => ' '/^extension_dir/{print $2; exit}')
  ini=$(echo "$full" | awk -F' => ' '/^Loaded Configuration File/{print $2; exit}')
  inipath=$(echo "$full" | awk -F' => ' '/^Configuration File \(php.ini\) Path/{print $2; exit}')
  scan=$(echo "$full" | awk -F' => ' '/^Scan this dir for additional .ini files/{print $2; exit}')
  echo "$info" | awk -F' => ' '/^Configure Command/{sub(/^ +/,"",$2); sub(/ +$/,"",$2); print $2; exit}' > "$d/configure.txt"
  echo "$full" > "$d/phpinfo.txt"
  "$r" -m > "$d/modules.txt" 2>"$d/modules.stderr" || true
  "$r" -n -m > "$d/builtin-modules.txt" 2>/dev/null || true
  ldd "$r" > "$d/ldd.txt" 2>&1 || true
  sha=$(sha256sum "$r" | cut -d' ' -f1)
  own=$(owner "$r")
  # a distro package hides its configure command; its changelog says whether the vendor fixed PHP2Shell
  vendor=unknown
  if [ "$own" != - ] && command -v dpkg-query >/dev/null 2>&1; then
    src=$(dpkg-query -W -f='${source:Package}' "$own" 2>/dev/null); src=${src:-$own}
    cl=$(ls /usr/share/doc/"$own"/changelog.Debian.gz 2>/dev/null | head -1)
    if [ -n "$cl" ]; then
      if zgrep -q -E 'CVE-2026-10961[89]' "$cl"; then vendor=fixed; else vendor=not-in-changelog; fi
    fi
    echo "dpkg_version=$(dpkg-query -W -f='${Version}' "$own" 2>/dev/null)" >> "$d/pkg.txt"
    echo "dpkg_source=$src" >> "$d/pkg.txt"
  elif [ "$own" != - ] && command -v rpm >/dev/null 2>&1; then
    if rpm -q --changelog "$own" 2>/dev/null | grep -q -E 'CVE-2026-10961[89]'; then vendor=fixed; else vendor=not-in-changelog; fi
  fi
  printf '%s\n' "path=$b" "real=$r" "version=$ver" "sapi=$sapi" "api=$api" "modapi=$modapi" "zendapi=$zendapi" \
    "build=$build" "extension_dir=$extdir" "ini=$ini" "ini_path=$inipath" "scan_dir=$scan" \
    "sha256=$sha" "owner=$own" "vendor_fix=$vendor" > "$d/meta.txt"
  [ -s "$d/configure.txt" ] || echo "    no configure command in php -i (distro build); vendor fix: $vendor"
  # libraries outside the system directories must be supplied to the build (generic/build.sh --extra)
  awk '/=>/ && $3 ~ /^\// {print $3}' "$d/ldd.txt" | grep -v -E '^/(usr/)?lib(64|32|x32)?/' > "$d/custom-libs.txt" || true
  [ -s "$d/custom-libs.txt" ] && echo "    links libraries outside /lib and /usr/lib: $(tr '\n' ' ' < "$d/custom-libs.txt")"
  printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$r" "$ver" "$sapi" "$extdir" >> "$P/binaries.tsv"
  echo "found: $r  PHP $ver ($sapi)"
done

[ "$n" -gt 0 ] || { echo "no PHP binary found (name them: bash collect.sh /path/to/php-fpm)"; exit 1; }

# --- shared extensions, once per extension dir -----------------------------------------------
cut -f5 "$P/binaries.tsv" | sort -u | while read -r ed; do
  [ -d "$ed" ] || continue
  key=$(echo "$ed" | tr '/' '_')
  for so in "$ed"/*.so; do
    [ -f "$so" ] || continue
    printf '%s\t%s\t%s\n' "$(basename "$so")" "$(sha256sum "$so" | cut -d' ' -f1)" "$(owner "$so")"
  done > "$P/ext$key.tsv"
done

# apache2handler (mod_php) cannot be rebuilt from here: say so
shopt -s nullglob
for m in /usr/lib/apache2/modules/libphp*.so /usr/lib64/httpd/modules/libphp*.so; do
  echo "$m" >> "$P/mod_php.txt"
  echo "NOTE: mod_php found ($m): generic mode rebuilds CLI, FPM and CGI only; move the sites to FPM or patch mod_php another way."
done
shopt -u nullglob

tar -czf "$OUT.tar.gz" -C "$T" "$OUT"
echo "profile: $PWD/$OUT.tar.gz ($n binaries)"

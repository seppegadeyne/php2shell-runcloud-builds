#!/bin/bash
# Generic mode, step 3: install a generic build on the server it was built for. Run as root.
#
#   bash deploy.sh <tarball>             swap the binaries listed in its MANIFEST
#   bash deploy.sh <tarball> rollback    put the originals back
#   bash deploy.sh <tarball> check       only test: does the new binary start with the real config?
#
# Safety rules:
#  - every target must still have the SHA-256 the profile recorded (or already be the new file);
#    a server that changed since collect.sh is refused, so collect again and rebuild
#  - the new CLI must start with the server's own php.ini and extensions without a warning
#  - originals are copied once to /root/php2shell-generic-backup/<job>/ and never overwritten
#  - files are swapped by rename, so running processes keep their old inode
#  - a binary owned by a package is put on hold (apt-mark / versionlock) so updates do not undo it
#  - each PHP-FPM service that runs a replaced binary is config-tested and restarted;
#    a failed test or start rolls everything back
set -euo pipefail
TB=$(realpath "${1:?usage: deploy.sh <tarball> [rollback|check]}")
MODE=${2:-deploy}
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
tar -xzf "$TB" -C "$T"
M=$T/MANIFEST
[ -f "$M" ] || { echo "not a generic build (no MANIFEST)"; exit 1; }
JOB=$(sed -n 's/^job=//p' "$M"); HOSTM=$(sed -n 's/^host=//p' "$M")
BK=/root/php2shell-generic-backup/$JOB
THISHOST=$(hostname -s 2>/dev/null || hostname)
[ "$HOSTM" = "$THISHOST" ] || echo "WARNING: built for host '$HOSTM', this is '$THISHOST'"

mapfile -t REPL < <(sed -n 's/^replace=//p' "$M")
mapfile -t EXTS < <(sed -n 's/^ext=//p' "$M")

hold() {  # hold|unhold <file>
  local f=$1 act=$2 pkg=""
  if command -v dpkg-query >/dev/null 2>&1; then
    pkg=$(dpkg-query -S "$f" 2>/dev/null | head -1 | cut -d: -f1 || true)
    [ -n "$pkg" ] && apt-mark "$act" "$pkg" >/dev/null && echo "$act: $pkg"
  elif command -v rpm >/dev/null 2>&1; then
    pkg=$(rpm -qf --qf '%{NAME}\n' "$f" 2>/dev/null | grep -v 'not owned' | head -1 || true)
    if [ -n "$pkg" ] && command -v dnf >/dev/null 2>&1; then
      if [ "$act" = hold ]; then dnf -q versionlock add "$pkg" >/dev/null 2>&1 || echo "note: install dnf-plugin-versionlock to hold $pkg"
      else dnf -q versionlock delete "$pkg" >/dev/null 2>&1 || true; fi
    fi
  fi
  return 0
}

fpm_services() {  # services whose main process runs <binary>
  local bin=$1 u pid exe
  [ -d /run/systemd/system ] || return 0
  for u in $(systemctl list-units --type=service --state=running --no-legend --plain | awk '{print $1}'); do
    pid=$(systemctl show -p MainPID --value "$u" 2>/dev/null); [ "${pid:-0}" -gt 0 ] || continue
    exe=$(readlink "/proc/$pid/exe" 2>/dev/null || true); exe=${exe% (deleted)}
    [ "$exe" = "$bin" ] && echo "$u"
  done
  return 0
}

fpm_test() {  # fpm_test <binary> <unit>: config test with the unit's own --fpm-config / -y
  local bin=$1 u=$2 cmd conf
  cmd=$(systemctl show -p ExecStart --value "$u" 2>/dev/null | sed -n 's/.*argv\[\]=\([^;]*\);.*/\1/p')
  conf=$(echo "$cmd" | grep -o -E '(--fpm-config|-y)[ =][^ ]+' | head -1 | sed -E 's/^(--fpm-config|-y)[ =]//')
  if [ -n "$conf" ]; then "$bin" -t -y "$conf"; else "$bin" -t; fi
}

# which services run the FPM binaries we touch (decided before the swap)
declare -A UNITS=()
for r in "${REPL[@]}"; do
  IFS='|' read -r staged real osha sapi <<< "$r"
  case $sapi in *FPM*) for u in $(fpm_services "$real"); do UNITS[$u]=$real; done ;; esac
done

restart_units() {
  local u
  [ "${#UNITS[@]}" -gt 0 ] || return 0
  for u in "${!UNITS[@]}"; do
    fpm_test "${UNITS[$u]}" "$u" || return 1
    systemctl restart "$u"; sleep 2
    systemctl is-active --quiet "$u" || { echo "$u did not start"; return 1; }
    echo "restarted: $u"
  done
}

if [ "$MODE" = rollback ]; then
  [ -d "$BK" ] || { echo "no backup in $BK"; exit 1; }
  for r in "${REPL[@]}"; do
    IFS='|' read -r staged real osha sapi <<< "$r"
    [ -f "$BK$real" ] && { cp -a "$BK$real" "$real.php2shell-rb" && mv -f "$real.php2shell-rb" "$real"; hold "$real" unhold; }
  done
  for e in "${EXTS[@]}"; do
    [ -f "$BK$e" ] && cp -a "$BK$e" "$e.php2shell-rb" && mv -f "$e.php2shell-rb" "$e"
  done
  restart_units || true
  echo "ROLLBACK OK ($JOB)"; exit 0
fi

# 1) every target still is the file the profile saw (or already the new one)
for r in "${REPL[@]}"; do
  IFS='|' read -r staged real osha sapi <<< "$r"
  [ -f "$real" ] || { echo "ABORT: $real does not exist"; exit 1; }
  cur=$(sha256sum "$real" | cut -d' ' -f1); new=$(sha256sum "$T$staged" | cut -d' ' -f1)
  if [ "$cur" != "$osha" ] && [ "$cur" != "$new" ]; then
    echo "ABORT: $real changed since the profile was taken (collect and build again)"; exit 1
  fi
done

# 2) the new CLI starts with the real configuration (its compiled-in php.ini path and
#    extension_dir are the server's), with no warning
CLI=$(for r in "${REPL[@]}"; do IFS='|' read -r s _ _ sp <<< "$r"; case $sp in *Command*) echo "$T$s";; esac; done | head -1)
[ -n "$CLI" ] || CLI=$(find "$T" -type f -path '*/bin/php*' ! -name 'php-c*' ! -name 'phpize*' | head -1)
if [ -n "$CLI" ]; then
  "$CLI" -m > "$T/mods" 2> "$T/err" || true
  if grep -qi -E 'warning|error' "$T/err"; then cat "$T/err"; echo "ABORT: startup warnings with the server's configuration"; exit 1; fi
  # out of memory must end the process without running shutdown functions (the PHP2Shell fix)
  if grep -q -v '=none' <(grep '^patch=' "$M"); then
    o=$("$CLI" -d memory_limit=8M -r 'register_shutdown_function(function(){echo "shutdown-ran\n";}); $a=str_repeat("x", 64*1024*1024);' 2>/dev/null || true)
    echo "$o" | grep -q shutdown-ran && { echo "ABORT: the new binary still runs shutdown functions after an out-of-memory error"; exit 1; }
  fi
  echo "check: new CLI loads $(grep -c -v -E '^\[|^$' "$T/mods") modules, no warnings"
fi
[ "$MODE" = check ] && { echo "CHECK OK ($JOB)"; exit 0; }

# 3) back up the originals once
if [ ! -d "$BK" ]; then
  for r in "${REPL[@]}"; do IFS='|' read -r staged real osha sapi <<< "$r"; mkdir -p "$BK$(dirname "$real")"; cp -a "$real" "$BK$real"; done
  for e in "${EXTS[@]}"; do [ -f "$e" ] && { mkdir -p "$BK$(dirname "$e")"; cp -a "$e" "$BK$e"; }; done
  cp "$M" "$BK/MANIFEST"
fi

# 4) swap by rename
for r in "${REPL[@]}"; do
  IFS='|' read -r staged real osha sapi <<< "$r"
  install -m 755 "$T$staged" "$real.php2shell-new" && mv -f "$real.php2shell-new" "$real"
  hold "$real" hold
done
n=0
for e in "${EXTS[@]}"; do
  [ -f "$e" ] && [ -f "$T$e" ] || continue      # only extensions the server already has
  install -m 755 "$T$e" "$e.php2shell-new" && mv -f "$e.php2shell-new" "$e"; n=$((n+1))
done
echo "swapped: ${#REPL[@]} binaries, $n shared extensions from the core"

# 5) restart the FPM services that ran a replaced binary; roll back on failure
if ! restart_units; then
  echo "FPM TEST OR START FAILED -> rollback"; exec bash "$0" "$TB" rollback
fi
if [ "${#UNITS[@]}" -eq 0 ]; then echo "no running PHP-FPM service uses these binaries (nothing restarted; restart it yourself if it runs outside systemd)"; fi
echo "DEPLOY OK ($JOB): $(sed -n 's/^php=//p' "$M"), patch $(sed -n 's/^patch=//p' "$M")"

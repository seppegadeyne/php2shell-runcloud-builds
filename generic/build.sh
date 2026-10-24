#!/bin/bash
# Generic mode, step 2: build patched PHP for a server from its profile (generic/collect.sh).
# Runs on a build machine (Linux x86_64, rootless, same requirements as ../build.sh).
#
#   generic/build.sh <profile.tar.gz> [--only b1,b2] [--extra <tarball-of-/opt/...>]
#
# Per binary in the profile that carries a configure command, it builds the newest release of
# the same PHP branch (versions.tsv), patched for PHP2Shell where php.net has no fix, with the
# server's configure command verbatim, inside the server's own Ubuntu release (ubuntu-base),
# so the result links the same glibc, OpenSSL and ICU and the same extension API.
# Binaries with the same version and configure command are built once.
#
# --extra: a tarball unpacked at / inside the build root first, for libraries the server links
#          from outside /lib and /usr/lib (collect.sh lists them per binary in custom-libs.txt).
#
# Output: out/generic/<host>/php<version>-<job>.tar.gz + MANIFEST + SHA256SUMS
set -euo pipefail
cd "$(dirname "$(realpath "$0")")/.."
TOP=$PWD
PROF=$(realpath "${1:?usage: generic/build.sh <profile.tar.gz> [--only b1,b2] [--extra tarball]}"); shift
ONLY=""; EXTRA=""
while [ $# -gt 0 ]; do
  case $1 in
    --only) ONLY=",$2,"; shift 2 ;;
    --extra) EXTRA=$(realpath "$2"); shift 2 ;;
    *) echo "unknown option $1"; exit 1 ;;
  esac
done

grep -q "^$(id -un):" /etc/subuid && grep -q "^$(id -un):" /etc/subgid || {
  echo "Your user needs a range in /etc/subuid and /etc/subgid (see README)."; exit 1; }

W=$TOP/work; DL=$W/downloads; mkdir -p "$DL"
PW=$(mktemp -d); trap 'rm -rf "$PW"' EXIT
tar -xzf "$PROF" -C "$PW"
P=$(find "$PW" -mindepth 1 -maxdepth 1 -type d | head -1)
HOST=$(sed -n 's/^host=//p' "$P/server.txt")

# --- the server's release ---------------------------------------------------------------------
# shellcheck disable=SC1091
. "$P/os-release"
[ "${ID:-}" = ubuntu ] || { echo "generic mode builds for Ubuntu servers only (this one: ${ID:-unknown} ${VERSION_ID:-}).
For other distributions build in a matching root filesystem by hand with generic/chroot-build.sh."; exit 1; }
DIST=${VERSION_CODENAME:-}
case $DIST in
  xenial) UBASE=16.04; UREL=16.04.6 ;;
  bionic) UBASE=18.04; UREL=18.04.5 ;;
  focal)  UBASE=20.04; UREL=20.04.5 ;;
  jammy)  UBASE=22.04; UREL=22.04.5 ;;
  noble)  UBASE=24.04; UREL=24.04.5 ;;
  *) echo "unsupported Ubuntu release: ${DIST:-?}"; exit 1 ;;
esac

fetch() {  # fetch <url> <file>, checked against sources.sha256
  local url=$1 f=$2
  [ -f "$DL/$f" ] || { curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 -o "$DL/$f.part" "$url"; mv "$DL/$f.part" "$DL/$f"; }
  local want; want=$(awk -v f="$f" '$2==f{print $1}' "$TOP/sources.sha256")
  [ -n "$want" ] || { echo "no checksum for $f in sources.sha256"; exit 1; }
  echo "$want  $DL/$f" | sha256sum -c --quiet || { echo "CHECKSUM MISMATCH: $f"; exit 1; }
}

# --- plan: which binaries, which jobs ---------------------------------------------------------
declare -A JOBVER=() JOBPATCH=() JOBBINS=() JOBOPC=()
: > "$PW/skipped.txt"
while IFS=$'\t' read -r id real ver sapi extdir; do
  [ -z "$ONLY" ] || [[ "$ONLY" == *",$id,"* ]] || continue
  d=$P/bin/$id
  if [ ! -s "$d/configure.txt" ]; then
    vf=$(sed -n 's/^vendor_fix=//p' "$d/meta.txt"); own=$(sed -n 's/^owner=//p' "$d/meta.txt")
    echo "skip $id $real: distro build without a configure command (package $own, vendor fix: $vf)" | tee -a "$PW/skipped.txt"
    continue
  fi
  branch=$(echo "$ver" | grep -o -E '^[0-9]+\.[0-9]+')
  row=$(awk -F'\t' -v b="$branch" '!/^#/ && $1==b' generic/versions.tsv)
  [ -n "$row" ] || { echo "skip $id $real: PHP $branch is not covered" | tee -a "$PW/skipped.txt"; continue; }
  bver=$(echo "$row" | cut -f2); patch=$(echo "$row" | cut -f3)
  key=$(printf '%s\n%s' "$bver" "$(cat "$d/configure.txt")" | sha256sum | cut -c1-10)
  job=j$key
  JOBVER[$job]=$bver; JOBPATCH[$job]=$patch
  JOBBINS[$job]="${JOBBINS[$job]:-} $id"
  # a separately packaged opcache.so on the server, while the build would make opcache static or none
  if grep -q -P '^opcache\.so\t' "$P"/ext"$(echo "$extdir" | tr '/' '_')".tsv 2>/dev/null; then
    JOBOPC[$job]=1
  fi
  echo "plan $id $real: PHP $ver -> $bver (${patch}) job $job"
done < "$P/binaries.tsv"
[ "${#JOBVER[@]}" -gt 0 ] || { echo "nothing to build (see the skip lines above)"; exit 1; }

# --- build root -----------------------------------------------------------------------------
R=$W/rootfs-generic-$DIST
UB=ubuntu-base-$UREL-base-amd64.tar.gz
fetch "https://cdimage.ubuntu.com/ubuntu-base/releases/$UBASE/release/$UB" "$UB"
if [ ! -f "$R/etc/os-release" ]; then
  mkdir -p "$R"
  unshare --user --map-root-user --map-users=auto --map-groups=auto \
    tar -xzf "$DL/$UB" -C "$R" --exclude='./dev/*' 2>/dev/null || true
fi
mkdir -p "$R/src"
cp generic/chroot-deps.sh generic/chroot-build.sh patches/*.patch "$R/src/"
if [ -n "$EXTRA" ]; then
  cp "$EXTRA" "$R/src/extra.tar.gz"
  scripts/enter.sh "$R" tar -xzf /src/extra.tar.gz -C /
fi
scripts/enter.sh "$R" /src/chroot-deps.sh "$DIST"

OUT=$TOP/out/generic/$HOST; mkdir -p "$OUT"
for job in "${!JOBVER[@]}"; do
  ver=${JOBVER[$job]}; patch=${JOBPATCH[$job]}
  first=$(echo "${JOBBINS[$job]}" | awk '{print $1}')
  echo "=== $job: PHP $ver for${JOBBINS[$job]} (patch: $patch)"
  fetch "https://www.php.net/distributions/php-$ver.tar.xz" "php-$ver.tar.xz"
  cp "$DL/php-$ver.tar.xz" "$R/src/"
  [ "$patch" = none ] || grep -q " $patch\$" sources.sha256
  rm -rf "${R:?}/src/$job"; mkdir -p "$R/src/$job"
  cp "$P/bin/$first/configure.txt" "$R/src/$job/"
  [ -n "${JOBOPC[$job]:-}" ] && touch "$R/src/$job/want-opcache"
  scripts/enter.sh "$R" /src/chroot-build.sh "$ver" "$patch" "$job"

  # manifest: which staged file replaces which file on the server
  M=$R/src/$job/MANIFEST
  { echo "host=$HOST"; echo "dist=$DIST"; echo "php=$ver"; echo "patch=$patch"; echo "job=$job"
    grep -E '^(modapi|buildid|extension_dir)=' "$R/src/$job/build-info.txt"; } > "$M"
  for id in ${JOBBINS[$job]}; do
    real=$(sed -n 's/^real=//p' "$P/bin/$id/meta.txt")
    smod=$(sed -n 's/^modapi=//p' "$P/bin/$id/meta.txt")
    bmod=$(sed -n 's/^modapi=//p' "$R/src/$job/build-info.txt")
    [ "$smod" = "$bmod" ] || { echo "ABORT: $real has extension API $smod, the build $bmod"; exit 1; }
    sapi=$(sed -n 's/^sapi=//p' "$P/bin/$id/meta.txt")
    case $sapi in
      *FPM*) pat='sbin/php-fpm' ;;
      *CGI*) pat='bin/php-cgi' ;;
      *)     pat='bin/php' ;;
    esac
    staged=$(grep '^binary=' "$R/src/$job/build-info.txt" | cut -d= -f2 | grep -E "/$pat[0-9.]*\$" | head -1)
    [ -n "$staged" ] || { echo "ABORT: the build has no $pat for $real"; exit 1; }
    [ "$staged" = "$real" ] || echo "note: $real is built as $staged (symlink or renamed binary on the server)"
    echo "replace=$staged|$real|$(sed -n 's/^sha256=//p' "$P/bin/$id/meta.txt")|$sapi" >> "$M"
    # builtin modules must match, or sites lose a function
    if [ -s "$P/bin/$id/builtin-modules.txt" ]; then
      bl=$R/src/$job/builtin-$(basename "$staged").txt
      [ -s "$bl" ] || bl=$R/src/$job/builtin-modules.txt
      miss=$(comm -23 <(grep -v -E '^\[|^$' "$P/bin/$id/builtin-modules.txt" | sort -u) <(grep -v -E '^\[|^$' "$bl" | sort -u) | tr '\n' ' ')
      [ -z "${miss// }" ] || { echo "ABORT: built-in modules missing in the build for $real: $miss"; exit 1; }
    fi
  done
  # shared extensions built from the core, replaced only where the server has the same file
  extdir=$(sed -n 's/^extension_dir=//p' "$R/src/$job/build-info.txt")
  for e in $(grep '^ext=' "$R/src/$job/build-info.txt" | cut -d= -f2); do
    echo "ext=$extdir/$e" >> "$M"
  done
  name=php$ver-$( [ "$patch" = none ] || echo php2shell- )$job
  # shellcheck disable=SC2015
  ( cd "$R/stage-$job" && cp "$M" ./MANIFEST && tar -czf "$OUT/$name.tar.gz" . )
  echo "OUT $OUT/$name.tar.gz"
done
cp "$PW/skipped.txt" "$OUT/SKIPPED.txt"
( cd "$OUT" && sha256sum -- *.tar.gz > SHA256SUMS )
echo "done: $(ls "$OUT"/*.tar.gz | wc -l) tarball(s) in $OUT"

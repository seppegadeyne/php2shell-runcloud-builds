#!/bin/bash
# Enter an Ubuntu root filesystem as a rootless chroot (user namespace).
# No sudo, no Docker daemon. Needs a subuid/subgid range for your user.
# usage: scripts/enter.sh <rootfs-dir> <command...>
set -euo pipefail
HERE=$(dirname "$(realpath "$0")")
R=$(realpath "$1"); shift
exec unshare --user --map-root-user --map-users=auto --map-groups=auto \
  --mount --pid --fork --kill-child "$HERE/_inner.sh" "$R" "$@"

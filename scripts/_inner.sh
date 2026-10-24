#!/bin/bash
# Runs as "root" inside the new namespaces created by enter.sh.
R="$1"; shift
mount --rbind /dev "$R/dev" 2>/dev/null || true
mount -t proc proc "$R/proc"
mount -t tmpfs tmpfs "$R/tmp"
cp /etc/resolv.conf "$R/etc/resolv.conf"
exec chroot "$R" /usr/bin/env -i HOME=/root \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  LANG=C.UTF-8 DEBIAN_FRONTEND=noninteractive "$@"

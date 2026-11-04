#!/bin/sh
# Project Reclaimer under Wine binds 127.0.0.x, 127.0.1.x, 127.0.2.x (0.9.8+), 127.3.1.x and 127.3.2.x (0.9.13), a
# different host each session; macOS only has 127.0.0.1 on lo0 and only binds exact addresses.
# Runs as root at boot, so it reads no arguments or environment. It adds only what lo0 is missing, 50 at a time with a
# pause: all ~1,800 in one burst stalled configd on Macs with VPNs and kernel-panicked them (#37).
PATH=/usr/bin:/bin:/usr/sbin:/sbin
have=$(/sbin/ifconfig lo0)
n=0
for p in 127.0.0 127.0.1 127.0.2 127.3.1 127.3.2; do
  i=1
  while [ $i -le 254 ]; do
    a="$p.$i"
    i=$((i+1))
    case "$have" in *"inet $a "*) continue ;; esac
    /sbin/ifconfig lo0 alias "$a" netmask 255.255.255.255 2>/dev/null
    n=$((n+1))
    [ $((n % 50)) -eq 0 ] && /bin/sleep 1
  done
done
exit 0

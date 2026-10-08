#!/bin/sh
# Project Reclaimer under Wine binds 127.0.0.x, 127.0.1.x and 127.3.1.x; macOS only has 127.0.0.1 on lo0 by default
for p in 127.0.0 127.0.1 127.3.1; do
  i=1
  while [ $i -le 254 ]; do
    [ "$p.$i" = 127.0.0.1 ] && { i=$((i+1)); continue; }
    /sbin/ifconfig lo0 alias "$p.$i" netmask 255.255.255.255 2>/dev/null
    i=$((i+1))
  done
done

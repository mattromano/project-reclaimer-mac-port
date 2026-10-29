#!/bin/sh
# The local addresses Project Reclaimer binds under Wine, added to lo0. macOS only has 127.0.0.1 there, and a program
# can only bind an address that was added on its own (a netmask covering it isn't enough), so each range needs every
# host:
#   127.0.1.N, 127.0.2.N  the client's slot N, a different one each session ("Local client slot N: transport
#                         127.0.1.N, native bind 127.0.2.N", 0.9.8 to 0.9.23)
#   127.3.1.x, 127.3.2.x  the native UDP bind: one address the client works out, which moves between releases
#                         (127.3.1.64 on 0.9.11, 127.3.2.124 on 0.9.13, 127.3.1.88 on 0.9.23)
# launchd starts this when the launcher asks (see the plist), never at boot: adding ~1,800 at every boot stalled configd
# on Macs with VPNs and kernel-panicked them (#37). It runs as root, so it takes no input: no arguments, no environment,
# and it never touches the folder the launcher asks through. It adds only what lo0 is missing, 25 at a time, and times
# configd's answer after each batch: slow means wait for it, no answer means stop. It then takes back what this run
# added, paced and checked the same way, once configd answers again; if it doesn't, the rest stays (aliases sitting on
# lo0 are harmless: the churn of changing them is what hurts).
PATH=/usr/bin:/bin:/usr/sbin:/sbin
dir="/Library/Application Support/ProjectReclaimer"

status() {  # how the last run went ($result), for the launcher (in root's own folder)
  [ -d "$dir" ] || return 0
  printf '%s\n' "$result" > "$dir/loopback.status.new" && /bin/mv -f "$dir/loopback.status.new" "$dir/loopback.status"
}

answer_time() {  # tenths of a second configd takes to answer, or "none" after 8 s without an answer
  /usr/sbin/scutil --nwi >/dev/null 2>&1 &
  pid=$!
  t=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$t" -ge 80 ]; then
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      echo none
      return
    fi
    /bin/sleep 0.1
    t=$((t + 1))
  done
  wait "$pid" 2>/dev/null
  echo "$t"
}

configd_ok() {  # after a batch: false when configd stops answering, or stays slower than 2 s for about a minute
  tries=0
  while :; do
    t=$(answer_time)
    echo "configd: $t"
    [ "$t" = none ] && return 1
    [ "$t" -le 20 ] && return 0
    tries=$((tries + 1))
    [ "$tries" -ge 15 ] && return 1
    /bin/sleep 3
  done
}

recovered() {  # configd answers within 2 s again, within three tries; else false
  w=0
  until configd_ok; do
    w=$((w + 1))
    [ "$w" -ge 3 ] && return 1
    /bin/sleep 2
  done
}

take_back() {  # remove what this run added like it was added (removing is interface changes too); false if it stopped
  recovered || return 1
  n=0
  for a in $added; do
    /sbin/ifconfig lo0 -alias "$a" 2>/dev/null
    n=$((n + 1))
    [ $((n % 25)) -eq 0 ] || continue
    /bin/sleep 0.2
    configd_ok || return 1
  done
}

# not in the first two minutes after a boot, when configd is busiest (launchd doesn't start this then, but whatever
# starts it, that is the window that panicked Macs)
boot=$(/usr/sbin/sysctl -n kern.boottime | /usr/bin/sed -n 's/^{ sec = \([0-9]*\).*/\1/p')
up=$(($(/bin/date +%s) - ${boot:-0}))
[ "$up" -lt 120 ] && /bin/sleep $((120 - up))

result=adding; status
have=$(/sbin/ifconfig lo0)
added=""
n=0
for p in 127.0.1 127.0.2 127.3.1 127.3.2; do
  i=1
  while [ $i -le 254 ]; do
    a="$p.$i"
    i=$((i + 1))
    case "$have" in *"inet $a "*) continue ;; esac
    /sbin/ifconfig lo0 alias "$a" netmask 255.255.255.255 2>/dev/null || continue
    added="$added $a"
    n=$((n + 1))
    [ $((n % 25)) -eq 0 ] || continue
    /bin/sleep 0.2
    if ! configd_ok; then
      echo "configd isn't keeping up after $n addresses: taking them back"
      if take_back; then result=taken-back; else result=stopped; fi
      status
      exit 1
    fi
  done
done
echo "added $n"
result="ok $n"; status
exit 0

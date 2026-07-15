#!/bin/bash
set -eu
chain=DOCKER-USER
allow_comment=the-ai-crowd-moss-webhook-zbox-allow
established_comment=the-ai-crowd-moss-webhook-established
drop_comment=the-ai-crowd-moss-webhook-zbox-drop
for _ in $(seq 1 120); do
  if iptables -nL "$chain" >/dev/null 2>&1; then break; fi
  sleep 1
done
iptables -nL "$chain" >/dev/null 2>&1
allow=(-s 10.18.19.3/32 -p tcp -m conntrack --ctorigdstport 8644 -m comment --comment "$allow_comment" -j ACCEPT)
established=(-p tcp -m conntrack --ctorigdstport 8644 --ctstate ESTABLISHED,RELATED -m comment --comment "$established_comment" -j ACCEPT)
drop=(-p tcp -m conntrack --ctorigdstport 8644 -m comment --comment "$drop_comment" -j DROP)
iptables -C "$chain" "${allow[@]}" 2>/dev/null || iptables -I "$chain" 1 "${allow[@]}"
iptables -C "$chain" "${established[@]}" 2>/dev/null || iptables -I "$chain" 2 "${established[@]}"
iptables -C "$chain" "${drop[@]}" 2>/dev/null || iptables -I "$chain" 3 "${drop[@]}"

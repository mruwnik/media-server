#!/usr/bin/env bash
# host.sh — host-level health: disk space and Pi power/throttling.
set -uo pipefail
cd "$(dirname "$0")/.."
. ./lib.sh

section "host health"
for mp in / /media/data; do
    use=$(df -P "$mp" 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}')
    if [ -n "$use" ] && [ "$use" -lt 90 ]; then pass "disk $mp at ${use}%"
    else fail "disk $mp at ${use:-?}%" ">= 90% used"; fi
done

# Under-voltage / throttling — the documented cause of Pi wedges. vcgencmd needs
# the `video` group or root, so fall back to sudo and SKIP if neither works.
throttle_raw=""
if vcgencmd get_throttled >/dev/null 2>&1; then
    throttle_raw=$(vcgencmd get_throttled 2>/dev/null)
elif sudo -n vcgencmd get_throttled >/dev/null 2>&1; then
    throttle_raw=$(sudo -n vcgencmd get_throttled 2>/dev/null)
fi
if [ -n "$throttle_raw" ]; then
    thr=${throttle_raw#*=}
    if [ "$thr" = "0x0" ]; then pass "no throttling ($thr)"
    else fail "throttling/under-voltage" "$thr (see /var/log/blackbox)"; fi
else
    skip "throttling check" "vcgencmd needs the video group or sudo"
fi

finish

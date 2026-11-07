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
    # get_throttled is a bitfield; only some bits mean real trouble:
    #   0x1 under-voltage now      0x10000 under-voltage occurred
    #   0x4 currently throttled    0x40000 throttling occurred (hard, ~85C)
    # The soft-temperature-limit bits (0x8 now / 0x80000 occurred) are BENIGN:
    # the Pi4 soft limit is 60C and this box idles ~63C, so 0x80000 latches on
    # essentially every boot — alarming on it is pure noise. Arm-freq-cap bits
    # (0x2 / 0x20000) are a derivative of the above, so we don't alarm on them
    # standalone either. Mask = under-voltage + hard-throttle, now + sticky.
    # Sticky bits latch until reboot, so they alert only when newly set since
    # the last run; otherwise one hot spell re-alerts hourly for weeks.
    state=/var/lib/health-check/throttled
    prev=$(cat "$state" 2>/dev/null || echo 0x0)
    [ -w "${state%/*}" ] && echo "$thr" >"$state"
    danger=$(( (thr & 0x5) | (thr & 0x50000 & ~prev) ))
    if [ "$danger" -ne 0 ]; then
        kind="throttling"
        [ $(( danger & 0x10001 )) -ne 0 ] && kind="under-voltage"
        fail "$kind" "$thr (see /var/log/blackbox)"
    elif [ "$thr" = "0x0" ]; then
        pass "no throttling ($thr)"
    else
        pass "throttle word $thr: no new trouble (sticky bits already reported)"
    fi
else
    skip "throttling check" "vcgencmd needs the video group or sudo"
fi

finish

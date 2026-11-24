#!/usr/bin/env bash
# host.sh — host-level health: disk space, disk SMART and Pi power/throttling.
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

# SMART on the USB HDD holding /, /nix and /media/data. The baseline is the
# damage already accepted; raising it is a deliberate commit, not Pi state.
# -n standby: never spin the disk up just to read it.
smart_dev=/dev/disk/by-id/wwn-0x5000c500d5adbf14
declare -A smart_baseline=([5]=136 [197]=0 [198]=0)
declare -A smart_name=([5]=reallocated [197]=pending [198]=offline-uncorrectable)
smartctl=(smartctl)
[ "$(id -u)" -eq 0 ] || smartctl=(sudo -n smartctl)
smart=$("${smartctl[@]}" -d sat -n standby -H -A "$smart_dev" 2>/dev/null)
if grep -q 'STANDBY' <<<"$smart"; then
    skip "SMART" "disk in standby"
elif ! grep -q 'self-assessment' <<<"$smart"; then
    skip "SMART" "smartctl needs root or sudo"
else
    health=$(awk -F': ' '/self-assessment/ {print $2}' <<<"$smart")
    if [ "$health" = PASSED ]; then pass "SMART health $health"
    else fail "SMART health ${health:-?}" "$smart_dev"; fi
    for id in 5 197 198; do
        raw=$(awk -v id="$id" '$1 == id {print $10}' <<<"$smart")
        base=${smart_baseline[$id]}
        if [ -z "$raw" ]; then fail "SMART ${smart_name[$id]} sectors" "attribute $id missing"
        elif [ "$raw" -le "$base" ]; then pass "SMART ${smart_name[$id]} sectors $raw (baseline $base)"
        else fail "SMART ${smart_name[$id]} sectors $raw" "above baseline $base in tests/checks/host.sh"; fi
    done
fi

finish

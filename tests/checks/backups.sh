#!/usr/bin/env bash
# backups.sh — the filen-sync backup is armed, last ran successfully, and ran
# recently. A silently-stalled backup is the classic "looks healthy, isn't".
set -uo pipefail
cd "$(dirname "$0")/.."
. ./lib.sh

UNIT=filen-sync
MAX_AGE_MIN=60   # timer fires every 15 min; allow ~4 cycles of slack

section "backups (filen-sync)"

check_cmd "$UNIT.timer armed" systemctl is-active --quiet "$UNIT.timer"

res=$(systemctl show "$UNIT.service" -p Result --value 2>/dev/null)
if [ "$res" = success ]; then pass "last run result: success"
else fail "$UNIT result" "${res:-unknown}"; fi

# Recency from the last completion timestamp.
ts=$(systemctl show "$UNIT.service" -p ExecMainExitTimestamp --value 2>/dev/null)
if [ -n "$ts" ]; then
    last=$(date -d "$ts" +%s 2>/dev/null || echo 0)
    now=$(date +%s)
    age_min=$(( (now - last) / 60 ))
    if [ "$last" -gt 0 ] && [ "$age_min" -le "$MAX_AGE_MIN" ]; then
        pass "last backup ${age_min}m ago"
    else
        fail "backup stale" "last success ${age_min}m ago (> ${MAX_AGE_MIN}m)"
    fi
else
    fail "backup" "no completion timestamp (never ran?)"
fi

finish

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

now=$(date +%s)
state=$(systemctl show "$UNIT.service" -p ActiveState --value 2>/dev/null)

# A backup running *right now* is the strongest freshness signal there is — but
# systemd blanks Result and ExecMainExitTimestamp for the duration of an active
# run (they describe the main process, which hasn't exited yet). The hourly
# health-check collides with filen-sync's :00 timer tick every hour, so reading
# those mid-flight yields a bogus "never ran". So: an in-progress run counts as
# healthy, unless it has been running far longer than a backup ever should —
# the service is a no-timeout oneshot, so a genuinely stuck sync hangs forever
# and this branch is the only thing that would catch it.
case "$state" in
    active | activating | reloading)
        # ExecMainStartTimestamp tracks the *current* run's start. (Don't use
        # ActiveEnterTimestamp here — a oneshot never cleanly enters "active",
        # so it's empty or stale mid-run.)
        started=$(systemctl show "$UNIT.service" -p ExecMainStartTimestamp --value 2>/dev/null)
        start_s=$(date -d "$started" +%s 2>/dev/null || echo 0)
        run_min=$(( (now - start_s) / 60 ))
        if [ "$start_s" -gt 0 ] && [ "$run_min" -gt "$MAX_AGE_MIN" ]; then
            fail "backup stuck" "running ${run_min}m (> ${MAX_AGE_MIN}m)"
        else
            pass "backup in progress (${run_min}m)"
        fi
        ;;
    *)
        res=$(systemctl show "$UNIT.service" -p Result --value 2>/dev/null)
        if [ "$res" = success ]; then pass "last run result: success"
        else fail "$UNIT result" "${res:-unknown}"; fi

        # Recency from the last completion timestamp.
        ts=$(systemctl show "$UNIT.service" -p ExecMainExitTimestamp --value 2>/dev/null)
        if [ -n "$ts" ]; then
            last=$(date -d "$ts" +%s 2>/dev/null || echo 0)
            age_min=$(( (now - last) / 60 ))
            if [ "$last" -gt 0 ] && [ "$age_min" -le "$MAX_AGE_MIN" ]; then
                pass "last backup ${age_min}m ago"
            else
                fail "backup stale" "last success ${age_min}m ago (> ${MAX_AGE_MIN}m)"
            fi
        else
            fail "backup" "no completion timestamp (never ran?)"
        fi
        ;;
esac

finish

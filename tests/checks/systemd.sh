#!/usr/bin/env bash
# systemd.sh — long-running services active, nothing failed, timers armed.
set -uo pipefail
cd "$(dirname "$0")/.."
. ./lib.sh

# Long-running services that must be active right now.
SERVICES="nginx mpd mympd rtorrent flood calibre-web radicale mcp"
# Periodic oneshots driven by timers — checked via their .timer (the services
# themselves are inactive between runs, so is-active on them would be wrong).
TIMERS="filen-sync blackbox-recorder health-check nixos-update-check anime-check mcp-update ahiru-blog-update mpd-rescan"

section "services active"
for unit in $SERVICES; do
    check_cmd "$unit" systemctl is-active --quiet "$unit"
done

section "no failed units"
failed=$(systemctl list-units --state=failed --no-legend --plain 2>/dev/null | awk '{print $1}' | paste -sd' ' -)
if [ -z "$failed" ]; then pass "systemctl --failed is empty"; else fail "failed units" "$failed"; fi

section "scheduled timers armed"
for t in $TIMERS; do
    check_cmd "$t.timer" systemctl is-active --quiet "$t.timer"
done

finish

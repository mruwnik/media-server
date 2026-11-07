#!/usr/bin/env bash
# security.sh — compromise tripwires. See modules/services/security.nix.
set -uo pipefail
cd "$(dirname "$0")/.."
. ./lib.sh

section "security"

# Outbound flows logged by the out-watch chain. 65min overlaps the hourly run
# so nothing slips between runs; mcp is excluded since it has legit callers.
if ! journalctl -k -n 1 >/dev/null 2>&1; then
    skip "outbound from service users" "kernel journal needs root"
else
    hits=$(journalctl -k --since "-65min" -o cat 2>/dev/null \
        | grep -oE 'out-watch (nginx|mpd|radicale): .*DST=[^ ]+.*DPT=[0-9]+' \
        | sed -E 's/out-watch ([a-z]+): .*DST=([^ ]+).*DPT=([0-9]+)/\1->\2:\3/' \
        | sort | uniq -c | sort -rn | head -5 | awk '{print $2 " x" $1}' | paste -sd ' ' -)
    if [ -z "$hits" ]; then pass "no outbound from nginx/mpd/radicale"
    else fail "outbound from service user" "$hits"; fi
fi

finish

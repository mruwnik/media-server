#!/usr/bin/env bash
# security.sh — compromise tripwires. See modules/services/security.nix.
set -uo pipefail
cd "$(dirname "$0")/.."
. ./lib.sh

section "security"

top5() { sort | uniq -c | sort -rn | head -5 | awk '{c = $1; $1 = ""; print substr($0, 2) " x" c}' | paste -sd ' ' -; }

# Flows logged by the out-watch/out-block chains. 65min overlaps the hourly run
# so nothing slips between runs; mcp is excluded since it has legit callers.
if ! journalctl -k -n 1 >/dev/null 2>&1; then
    skip "outbound from service users" "kernel journal needs root"
else
    klog=$(journalctl -k --since "-65min" -o cat 2>/dev/null)
    hits=$(printf '%s\n' "$klog" \
        | grep -oE 'out-watch (nginx|mpd|radicale): .*DST=[^ ]+.*DPT=[0-9]+' \
        | sed -E 's/out-watch ([a-z]+): .*DST=([^ ]+).*DPT=([0-9]+)/\1->\2:\3/' | top5)
    if [ -z "$hits" ]; then pass "no outbound from nginx/mpd/radicale"
    else fail "outbound from service user" "$hits"; fi

    blocked=$(printf '%s\n' "$klog" | grep -oE 'out-block rtorrent: .*DST=[^ ]+( .*DPT=[0-9]+)?' \
        | sed -E 's/.*DST=([^ ]+)(.*DPT=([0-9]+))?.*/\1:\3/' | top5)
    if [ -z "$blocked" ]; then pass "no blocked rtorrent destinations"
    else fail "rtorrent tried our LAN or an admin port" "$blocked"; fi
fi

# Execs by services that never exec (audit key svc-exec), minus rtorrent's
# start-up shell calls and the lock check forked by its ExecStartPre (its other
# helpers are coreutils, excluded in the rule), and radicale's start-up log line
# (platform.platform() runs `uname -p`), and the preStart scripts of mpd and
# nginx, whose parent is the unit script's shell rather than systemd.
if ! auditctl -s >/dev/null 2>&1; then
    skip "service execs" "auditctl needs root"
else
    # Without a tty ausearch only reads the logs given --input-logs.
    # shellcheck disable=SC2046  # date and time are two ausearch arguments
    execs=$(LC_ALL=C ausearch --input-logs -k svc-exec -i -ts $(LC_ALL=C date -d -65min '+%x %T') 2>/dev/null \
        | awk 'BEGIN { RS = "----" }
               match($0, / uid=[^ ]+/) { u = substr($0, RSTART + 5, RLENGTH - 5) }
               match($0, /argc=[0-9]+ [^\n]*/) { print u ": " substr($0, RSTART, RLENGTH) }' \
        | sed -E 's/argc=[0-9]+ a0=//; s/ a[0-9]+=/ /g' \
        | grep -vE '^torrents: (sh -c "?(mkdir -p |echo >)/media/data/Unsorted/|/nix/store/[^ ]*-procps-[^ /]*/bin/pidof rtorrent ?$)|^radicale: uname -p ?$|^mpd: install -m 600 /nix/store/[^ ]*-mpd\.conf /run/mpd/mpd\.conf ?$|^nginx: /nix/store/[^ ]*-nginx-[^ /]*/bin/nginx -c /nix/store/[^ ]*-nginx\.conf -t ?$' \
        | cut -c1-100 | top5)
    if [ -z "$execs" ]; then pass "no execs by rtorrent/nginx/mpd/radicale"
    else fail "service executed a program" "$execs"; fi
fi

finish

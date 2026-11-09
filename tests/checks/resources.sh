#!/usr/bin/env bash
# resources.sh — system resource utilisation against thresholds. Mirrors the
# metrics the old monitoring.nix health-check watched (CPU temp, memory, load).
# Thresholds come from /etc/monitoring-config (env overrides, then defaults).
set -uo pipefail
cd "$(dirname "$0")/.."
. ./lib.sh

CFG=/etc/monitoring-config
# cfg KEY DEFAULT — read a numeric value from the YAML-ish config, else DEFAULT.
cfg() {
    local key="$1" def="$2" val=""
    if [ -r "$CFG" ]; then
        if command -v yq >/dev/null 2>&1; then
            val=$(yq -r ".${key} // empty" "$CFG" 2>/dev/null)
        else
            val=$(sed -n "s/^[[:space:]]*${key}:[[:space:]]*\([0-9][0-9]*\).*/\1/p" "$CFG" 2>/dev/null | head -1)
        fi
    fi
    printf '%s' "${val:-$def}"
}
TEMP_THRESHOLD="${TEMP_THRESHOLD:-$(cfg temp_threshold 73)}"
MEMORY_THRESHOLD="${MEMORY_THRESHOLD:-$(cfg memory_threshold 90)}"
SYN_SENT_THRESHOLD="${SYN_SENT_THRESHOLD:-$(cfg syn_sent_threshold 600)}"
PROC_SOCKETS_THRESHOLD="${PROC_SOCKETS_THRESHOLD:-$(cfg proc_sockets_threshold 500)}"
CONNTRACK_THRESHOLD="${CONNTRACK_THRESHOLD:-$(cfg conntrack_threshold 50)}"

section "resources"

# CPU temperature (°C).
if [ -r /sys/class/thermal/thermal_zone0/temp ]; then
    temp=$(( $(cat /sys/class/thermal/thermal_zone0/temp) / 1000 ))
    if [ "$temp" -lt "$TEMP_THRESHOLD" ]; then pass "CPU temp ${temp}°C (< ${TEMP_THRESHOLD})"
    else fail "CPU temp ${temp}°C" ">= ${TEMP_THRESHOLD}°C"; fi
else
    skip "CPU temp" "no thermal_zone0"
fi

# Memory usage (%).
mem_total=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
mem_avail=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
if [ -n "$mem_total" ] && [ "$mem_total" -gt 0 ] && [ -n "$mem_avail" ]; then
    mem_pct=$(( (mem_total - mem_avail) * 100 / mem_total ))
    if [ "$mem_pct" -lt "$MEMORY_THRESHOLD" ]; then pass "memory ${mem_pct}% used (< ${MEMORY_THRESHOLD})"
    else fail "memory ${mem_pct}% used" ">= ${MEMORY_THRESHOLD}%"; fi
else
    skip "memory" "could not read /proc/meminfo"
fi

# Load average — transient spikes are normal, so this is a WARNING (never pages).
load1=$(awk '{print $1}' /proc/loadavg)
cores=$(nproc 2>/dev/null || echo 1)
load_int=${load1%.*}
if [ "${load_int:-0}" -lt $(( cores * 2 )) ]; then pass "load ${load1} (cores: ${cores})"
else warn "load ${load1} high" ">= 2x ${cores} cores"; fi

# The ISP blocks our IP when we open too many connections at once.
section "network fan-out"

syn_sent=$(ss -Htn state syn-sent 2>/dev/null | wc -l)
if [ "$syn_sent" -le "$SYN_SENT_THRESHOLD" ]; then pass "${syn_sent} sockets in SYN-SENT (<= ${SYN_SENT_THRESHOLD})"
else fail "${syn_sent} sockets in SYN-SENT" "> ${SYN_SENT_THRESHOLD}"; fi

# Other users' socket owners are only visible to root.
read -r top_n top_proc < <(ss -Htuanp 2>/dev/null \
    | sed -n 's/.*users:(("\([^"]*\)",pid=\([0-9]*\).*/\1[\2]/p' | sort | uniq -c | sort -rn | head -1)
if [ -z "${top_n:-}" ]; then skip "sockets per process" "no owner info (needs root)"
elif [ "$top_n" -le "$PROC_SOCKETS_THRESHOLD" ]; then pass "busiest process ${top_proc} holds ${top_n} sockets (<= ${PROC_SOCKETS_THRESHOLD})"
else fail "${top_proc} holds ${top_n} sockets" "> ${PROC_SOCKETS_THRESHOLD}"; fi

ct=/proc/sys/net/netfilter/nf_conntrack
if [ -r "${ct}_count" ] && [ -r "${ct}_max" ]; then
    ct_count=$(cat "${ct}_count"); ct_max=$(cat "${ct}_max")
    ct_pct=$(( ct_count * 100 / ct_max ))
    if [ "$ct_pct" -le "$CONNTRACK_THRESHOLD" ]; then pass "conntrack ${ct_count}/${ct_max} (${ct_pct}%)"
    else fail "conntrack ${ct_count}/${ct_max} (${ct_pct}%)" "> ${CONNTRACK_THRESHOLD}%"; fi
else
    skip "conntrack table" "nf_conntrack not loaded"
fi

# torrents-syn (torrent.nix) caps rtorrent's outbound SYNs, so drops are expected:
# a warning to watch the trend, never an alert.
drops=$( { iptables -L torrents-syn -vxn; ip6tables -L torrents-syn -vxn; } 2>/dev/null \
    | awk '$3 == "DROP" {n += $1; found = 1} END {if (found) print n}')
state=/var/lib/health-check/torrents-syn-drops
prev=$(cat "$state" 2>/dev/null)
[ -n "$drops" ] && [ -w "${state%/*}" ] && echo "$drops" >"$state"
if [ -z "$drops" ]; then skip "torrents-syn drops" "chain missing or unreadable (needs root)"
elif [ -z "$prev" ]; then warn "torrents-syn dropped ${drops} SYNs" "cumulative, no previous run to diff"
else
    # A firewall reload zeroes the counter.
    delta=$(( drops >= prev ? drops - prev : drops ))
    if [ "$delta" -eq 0 ]; then pass "torrents-syn dropped no SYNs since last run"
    else warn "torrents-syn dropped ${delta} SYNs since last run" "rtorrent is hitting its SYN cap"; fi
fi

finish

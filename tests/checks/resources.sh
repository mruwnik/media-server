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

finish

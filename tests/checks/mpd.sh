#!/usr/bin/env bash
# mpd.sh — MPD control port responds and the HTTP stream is live.
set -uo pipefail
cd "$(dirname "$0")/.."
. ./lib.sh

section "MPD"
# Greeting on the control port is "OK MPD <version>". Connect in a subshell —
# `exec <>/dev/tcp ... 2>...` in the current shell would clobber its stderr.
greeting=$(exec 3<>/dev/tcp/127.0.0.1/6600 2>/dev/null && IFS= read -r -t 5 g <&3 && printf '%s' "$g")
case "$greeting" in
    OK\ MPD*) pass "control port :6600 (${greeting%$'\r'})" ;;
    "")       fail "control port :6600" "no response / connection refused" ;;
    *)        fail "control port :6600" "unexpected greeting '${greeting}'" ;;
esac

# The httpd output serves on demand (port bound only while MPD has a stream).
# An absent stream usually just means nothing is playing — worth noting but not
# an outage — so WARN, not FAIL (never pages).
ct=$(curl -s -o /dev/null -w '%{content_type}' --max-time 6 http://127.0.0.1:8030/ 2>/dev/null || true)
case "$ct" in
    audio/*) pass "HTTP stream :8030 is audio ($ct)" ;;
    *)       warn "HTTP stream :8030 not streaming" "is anything playing?" ;;
esac

finish

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
# Something is normally playing here, so an absent stream is a real signal —
# idle MPD or a dead encoder both warrant a look — hence FAIL not SKIP.
check_ctype "HTTP stream :8030 is audio" audio/ http://127.0.0.1:8030/

finish

# shellcheck shell=bash
#
# Shared helpers for the ahiru test battery. Source from a test script:
#   . "$(dirname "$0")/lib.sh"
#
# Provides coloured PASS/FAIL/SKIP output, running counters, and a handful of
# check_* helpers. Style mirrors maip-server's provision/monitoring/tests.
# No `set -e` on purpose — every check should run even if an earlier one fails.

if [ -t 1 ]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; CYAN=""; NC=""
fi

PASSED=0; FAILED=0; SKIPPED=0

section() { printf '\n%s== %s ==%s\n' "$CYAN" "$1" "$NC"; }
pass()    { printf '  %sPASS%s %s\n' "$GREEN" "$NC" "$1"; PASSED=$((PASSED + 1)); }
fail()    { printf '  %sFAIL%s %s%s\n' "$RED" "$NC" "$1" "${2:+ — $2}"; FAILED=$((FAILED + 1)); }
skip()    { printf '  %sSKIP%s %s%s\n' "$YELLOW" "$NC" "$1" "${2:+ — $2}"; SKIPPED=$((SKIPPED + 1)); }

# check_cmd "desc" cmd args...   — pass iff the command exits 0
check_cmd() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc" "\`$*\` exited $?"; fi
}

# check_http "desc" expected_code url [curl args...]
check_http() {
    local desc="$1" expected="$2" url="$3"; shift 3
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 30 "$@" "$url" 2>/dev/null || echo 000)
    if [ "$code" = "$expected" ]; then pass "$desc (HTTP $code)"
    elif [ "$code" = 000 ]; then fail "$desc" "connection failed"
    else fail "$desc" "HTTP $code, expected $expected"; fi
}

# check_up "desc" url [curl args...]   — pass iff we got ANY HTTP response
# (for upstreams whose exact status varies, e.g. 401 vs 200 — just liveness)
check_up() {
    local desc="$1" url="$2"; shift 2
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 15 "$@" "$url" 2>/dev/null || echo 000)
    if [ "$code" != 000 ]; then pass "$desc (HTTP $code)"; else fail "$desc" "no HTTP response"; fi
}

# check_content "desc" url substring [curl args...]
check_content() {
    local desc="$1" url="$2" needle="$3"; shift 3
    local body
    body=$(curl -s --compressed --connect-timeout 10 --max-time 30 "$@" "$url" 2>/dev/null || true)
    if printf '%s' "$body" | grep -qi -- "$needle"; then pass "$desc (found '$needle')"
    else fail "$desc" "missing '$needle'"; fi
}

# check_ctype "desc" expected_prefix url [curl args...]   — match Content-Type prefix
check_ctype() {
    local desc="$1" expected="$2" url="$3"; shift 3
    local ct
    ct=$(curl -s -o /dev/null -w '%{content_type}' --connect-timeout 10 --max-time 30 "$@" "$url" 2>/dev/null || true)
    case "$ct" in
        "$expected"*) pass "$desc ($ct)" ;;
        "")           fail "$desc" "no response" ;;
        *)            fail "$desc" "content-type '$ct', expected '$expected*'" ;;
    esac
}

# summary   — print totals; return non-zero iff anything failed
summary() {
    printf '\n%s========================================%s\n' "$CYAN" "$NC"
    printf '  %sPASS %d%s   %sFAIL %d%s   %sSKIP %d%s\n' \
        "$GREEN" "$PASSED" "$NC" "$RED" "$FAILED" "$NC" "$YELLOW" "$SKIPPED" "$NC"
    printf '%s========================================%s\n' "$CYAN" "$NC"
    [ "$FAILED" -eq 0 ]
}

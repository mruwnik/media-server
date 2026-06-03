# shellcheck shell=bash
#
# Shared helpers for the ahiru test battery. Source from a test script:
#   . "$(dirname "$0")/lib.sh"
#
# Output contract (mirrors maip-server's provision/monitoring/lib.sh):
#   stderr = the human report — section headers + PASS/FAIL/SKIP lines, coloured.
#   stdout = the alert payload — failure lines only, empty when healthy. This is
#            what `finish` prints so a checker can be piped:  diagnostics.sh | notify.sh
# No `set -e` on purpose — every check runs even if an earlier one fails.

if [ -t 2 ]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; CYAN=""; NC=""
fi

PASSED=0; FAILED=0; WARNED=0; SKIPPED=0
FAILURES=""   # newline-joined failure lines — the stdout payload

# Shared option: `-u user:pass` enables authenticated checks. Sourced scripts
# see the caller's positional params, so every check picks this up uniformly.
AUTH=""
[ "${1:-}" = "-u" ] && AUTH="${2:-}"

section() { printf '\n%s== %s ==%s\n' "$CYAN" "$1" "$NC" >&2; }
pass()    { printf '  %sPASS%s %s\n' "$GREEN" "$NC" "$1" >&2; PASSED=$((PASSED + 1)); }
skip()    { printf '  %sSKIP%s %s%s\n' "$YELLOW" "$NC" "$1" "${2:+ — $2}" >&2; SKIPPED=$((SKIPPED + 1)); }

# warn "desc" ["detail"] — a non-fatal observation. Goes to the human report
# (stderr) only; never enters the failure payload, so it does NOT trigger an
# alert. Use for things worth seeing but not paging on (transient load, idle
# stream, …).
warn()    { printf '  %sWARN%s %s%s\n' "$YELLOW" "$NC" "$1" "${2:+ — $2}" >&2; WARNED=$((WARNED + 1)); }

# fail "desc" ["detail"] — record one payload line (newlines collapsed so each
# failure stays a single line) and print it to the human report.
fail() {
    local line="$1${2:+ — $2}"
    line=$(printf '%s' "$line" | tr '\n' ' ')
    FAILURES="${FAILURES}${FAILURES:+$'\n'}${line}"
    printf '  %sFAIL%s %s\n' "$RED" "$NC" "$line" >&2
    FAILED=$((FAILED + 1))
}

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

# finish — print a compact per-checker tally to stderr, the failure payload to
# stdout (one line per failure, empty when healthy), and return non-zero iff
# anything failed. Each checks/*.sh ends with `finish`; diagnostics.sh prints
# the overall verdict after running them all.
finish() {
    printf '  %s(%d pass, %d fail, %d warn, %d skip)%s\n' "$CYAN" "$PASSED" "$FAILED" "$WARNED" "$SKIPPED" "$NC" >&2
    [ -z "$FAILURES" ] && return 0
    printf '%s\n' "$FAILURES"   # stdout = alert payload for notify.sh
    return 1
}

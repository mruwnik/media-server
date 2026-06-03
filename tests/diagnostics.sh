#!/usr/bin/env bash
#
# diagnostics.sh — full ahiru checker. Runs every checks/*.sh (the on-Pi
# component checks PLUS the public-domain checks, which hairpin through
# ahiru.pl / media.ahiru.pl so DNS/TLS/nginx are covered end to end).
#
# Output contract (see lib.sh): stderr = human report; stdout = failure lines
# only (empty when healthy). Pipe it to alert:
#   diagnostics.sh | notify.sh "ahiru health"
#
# Usage (run on the Pi):
#   ssh ahiru.pl 'cd ~/nixos && ./tests/diagnostics.sh [-u user:pass]'
# The -u creds enable the authenticated route checks (radicale, /books, …).
#
# To run a SUBSET (e.g. from the hourly monitor), invoke the check scripts
# directly:  tests/checks/systemd.sh tests/checks/backups.sh | notify.sh
#
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh   # for colours in the overall verdict line

# Order: cheap/local first, public (network) last.
CHECKS="systemd calibre media mpd torrent backups host public"

payload=$(mktemp "${TMPDIR:-/tmp}/ahiru-diag.XXXXXX")
trap 'rm -f "$payload"' EXIT

rc=0
for c in $CHECKS; do
    # stderr (the report) streams live; stdout (failures) is collected for notify.
    ./checks/"$c".sh "$@" >>"$payload" || rc=1
done

nfail=$(grep -c . "$payload" 2>/dev/null || echo 0)
if [ "$rc" -eq 0 ]; then
    printf '\n%s== OVERALL: HEALTHY ==%s\n' "$GREEN" "$NC" >&2
else
    printf '\n%s== OVERALL: UNHEALTHY — %d failing ==%s\n' "$RED" "$nfail" "$NC" >&2
fi

cat "$payload"   # stdout = aggregated alert payload
exit "$rc"

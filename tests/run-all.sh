#!/usr/bin/env bash
#
# Run the whole battery from your laptop: the external (public-surface) checks
# locally, then the on-Pi component checks over SSH. The Pi-side scripts are
# shipped to a temp dir, so the Pi's checkout does NOT need to be in sync.
#
#   ./tests/run-all.sh                       # external (no creds) + on-Pi
#   ./tests/run-all.sh -u user:pass          # also exercise authed external routes
#   AHIRU_SSH=192.168.1.50 ./tests/run-all.sh # override SSH host
#
set -uo pipefail
cd "$(dirname "$0")"

HOST="${AHIRU_SSH:-ahiru.pl}"
ext_rc=0
pi_rc=0

echo "######## External checks (from $(hostname -s 2>/dev/null || hostname)) ########"
./external.sh "$@" || ext_rc=$?

echo
echo "######## On-Pi checks ($HOST) ########"
tmp=$(ssh "$HOST" 'mktemp -d /tmp/ahiru-tests.XXXXXX') || { echo "ssh to $HOST failed" >&2; exit 2; }
scp -q lib.sh run-local.sh "$HOST:$tmp/"
# -t forces a TTY so colours + the mpd /dev/tcp greeting read behave.
ssh -t "$HOST" "cd '$tmp' && bash run-local.sh; rc=\$?; rm -rf '$tmp'; exit \$rc" || pi_rc=$?

echo
if [ "$ext_rc" -eq 0 ] && [ "$pi_rc" -eq 0 ]; then
    echo "ALL GREEN ✓"
    exit 0
fi
echo "FAILURES: external rc=$ext_rc, on-pi rc=$pi_rc"
exit 1

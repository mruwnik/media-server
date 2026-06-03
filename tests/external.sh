#!/usr/bin/env bash
#
# external.sh — public-surface checks from your laptop. Thin wrapper around
# checks/public.sh (DNS + TLS + endpoints + auth gate via the real domains).
#
#   ./tests/external.sh                 # public, unauthenticated surface
#   ./tests/external.sh -u user:pass    # also exercise authenticated routes
#
exec "$(dirname "$0")/checks/public.sh" "$@"

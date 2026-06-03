#!/usr/bin/env bash
#
# Public-surface checks — run from outside (your laptop) OR sourced by
# diagnostics.sh (which calls external_checks to exercise the real domains from
# the Pi). curl without -k validates TLS; the 401s prove the auth gate is live.
#
#   ./tests/external.sh                 # public, unauthenticated surface
#   ./tests/external.sh -u user:pass    # also exercise authenticated routes
#
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

BLOG=https://ahiru.pl
MEDIA=https://media.ahiru.pl

# external_checks [user:pass] — the public-domain checks. Defined as a function
# so diagnostics.sh can reuse it; emits via lib.sh's pass/fail (no finish here).
external_checks() {
    local auth="${1:-}"

    section "blog — ahiru.pl (TLS + content)"
    check_http    "homepage 200"             200 "$BLOG/"
    check_http    "404 page"                 404 "$BLOG/this-page-should-not-exist-12345"
    check_http    "MCP discovery 200"        200 "$BLOG/.well-known/oauth-authorization-server"

    section "media portal — media.ahiru.pl"
    check_http    "portal index 200"         200 "$MEDIA/"

    section "auth gate enforced (expect 401 without creds)"
    check_http    "/books/ gated"            401 "$MEDIA/books/"
    check_http    "/torrents/ gated"         401 "$MEDIA/torrents/"
    check_http    "/music/ gated"            401 "$MEDIA/music/"

    if [ -n "$auth" ]; then
        section "authenticated routes"
        check_http    "/books/ 200 with auth"    200 "$MEDIA/books/" -u "$auth"
        check_content "/books/ shows calibre UI"     "$MEDIA/books/" calibre -u "$auth"
        check_http    "/music/ 200 with auth"    200 "$MEDIA/music/" -u "$auth"
        check_http    "/torrents/ 200 with auth" 200 "$MEDIA/torrents/" -u "$auth"
    fi
}

# Run standalone (skipped when sourced by diagnostics.sh).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    auth=""
    [ "${1:-}" = "-u" ] && auth="${2:-}"
    external_checks "$auth"
    finish
fi

#!/usr/bin/env bash
#
# Public-surface checks — run THIS from outside (your laptop). Verifies DNS +
# TLS (curl without -k validates the cert), that the public endpoints answer,
# and that the basic-auth gate is actually enforced from the internet.
#
#   ./tests/external.sh                 # public, unauthenticated surface
#   ./tests/external.sh -u user:pass    # also exercise an authenticated route
#
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

BLOG=https://ahiru.pl
MEDIA=https://media.ahiru.pl
AUTH=""
[ "${1:-}" = "-u" ] && AUTH="${2:-}"

section "blog — ahiru.pl (TLS + content)"
check_http    "homepage 200"            200 "$BLOG/"
check_http    "404 page"                404 "$BLOG/this-page-should-not-exist-12345"
check_http    "MCP discovery 200"       200 "$BLOG/.well-known/oauth-authorization-server"

section "media portal — media.ahiru.pl"
check_http    "portal index 200"        200 "$MEDIA/"

section "auth gate enforced (expect 401 without creds)"
check_http    "/books/ gated"           401 "$MEDIA/books/"
check_http    "/torrents/ gated"        401 "$MEDIA/torrents/"
check_http    "/music/ gated"           401 "$MEDIA/music/"

if [ -n "$AUTH" ]; then
    section "authenticated routes"
    check_http    "/books/ 200 with auth"   200 "$MEDIA/books/" -u "$AUTH"
    check_content "/books/ shows calibre UI" "$MEDIA/books/" calibre -u "$AUTH"
    check_http    "/music/ 200 with auth"   200 "$MEDIA/music/" -u "$AUTH"
    check_http    "/torrents/ 200 with auth" 200 "$MEDIA/torrents/" -u "$AUTH"
fi

summary

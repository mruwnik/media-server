#!/usr/bin/env bash
# public.sh — the public-facing surface via the real domains: DNS + TLS (curl
# without -k validates the cert), the public endpoints, and the auth gate. Run
# from a laptop (see ../external.sh) or by diagnostics.sh on the Pi (hairpin).
# Pass `-u user:pass` to also exercise the authenticated routes.
set -uo pipefail
cd "$(dirname "$0")/.."
. ./lib.sh

BLOG=https://ahiru.pl
MEDIA=https://media.ahiru.pl

section "blog — ahiru.pl (TLS + content)"
check_http    "homepage 200"             200 "$BLOG/"
check_http    "404 page"                 404 "$BLOG/this-page-should-not-exist-12345"
check_http    "MCP discovery 200"        200 "$BLOG/.well-known/oauth-authorization-server"

section "media portal — media.ahiru.pl"
check_http    "portal index 200"         200 "$MEDIA/"

DIFFER=https://differ.ahiru.pl

section "auth gate enforced (expect 401 without creds)"
check_http    "differ gated"             401 "$DIFFER/"
check_http    "/books/ gated"            401 "$MEDIA/books/"
check_http    "/torrents/ gated"         401 "$MEDIA/torrents/"
check_http    "/music/ gated"            401 "$MEDIA/music/"

if [ -n "$AUTH" ]; then
    section "authenticated routes"
    check_http    "/books/ 200 with auth"    200 "$MEDIA/books/" -u "$AUTH"
    check_content "/books/ shows calibre UI"     "$MEDIA/books/" calibre -u "$AUTH"
    check_http    "/music/ 200 with auth"    200 "$MEDIA/music/" -u "$AUTH"
    check_http    "/torrents/ 200 with auth" 200 "$MEDIA/torrents/" -u "$AUTH"
    check_content "differ UI with auth"          "$DIFFER/" "Differ - Local Code Review" -u "$AUTH"
fi

finish

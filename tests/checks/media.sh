#!/usr/bin/env bash
# media.sh — the other media upstreams: mympd, flood, radicale (WebDAV), mcp.
# Goes beyond liveness for radicale/mcp to confirm they actually function.
set -uo pipefail
cd "$(dirname "$0")/.."
. ./lib.sh

section "media upstreams (localhost)"
check_up   "mympd (:8080)"  http://127.0.0.1:8080/
check_up   "flood (:3000)"  http://127.0.0.1:3000/

# radicale: a PROPFIND exercises the WebDAV layer. Without creds it must be
# gated (401) — that proves it parses the method AND enforces auth, not just
# that the port is open.
check_http "radicale PROPFIND gated (401)" 401 http://127.0.0.1:5232/ -X PROPFIND -H 'Depth:0'
if [ -n "$AUTH" ]; then
    check_http "radicale PROPFIND with auth (207)" 207 "http://127.0.0.1:5232/${AUTH%%:*}/" \
        -u "$AUTH" -X PROPFIND -H 'Depth:0'
fi

# mcp: the OAuth discovery doc must be served AND well-formed (has the auth
# endpoint), which is a real functional signal for the fastmcp server.
check_http    "mcp discovery (:3001) 200" 200 http://127.0.0.1:3001/.well-known/oauth-authorization-server
check_content "mcp OAuth metadata"            http://127.0.0.1:3001/.well-known/oauth-authorization-server authorization_endpoint

finish

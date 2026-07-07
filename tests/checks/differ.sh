#!/usr/bin/env bash
# differ.sh — differ code-review server (standalone on :8576, not proxied).
# UI page proves static serving; /api/sessions exercises the API + sqlite db;
# the OAuth discovery doc is the functional signal for the MCP endpoint.
set -uo pipefail
cd "$(dirname "$0")/.."
. ./lib.sh

section "differ (code review, :8576)"
check_content "differ UI served"          http://127.0.0.1:8576/ "Differ - Local Code Review"
check_http    "differ API sessions" 200   http://127.0.0.1:8576/api/sessions
check_content "differ MCP OAuth metadata" http://127.0.0.1:8576/.well-known/oauth-authorization-server authorization_endpoint

finish

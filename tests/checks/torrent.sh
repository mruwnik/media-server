#!/usr/bin/env bash
# torrent.sh — rtorrent's RPC socket is present (flood talks to it over this).
set -uo pipefail
cd "$(dirname "$0")/.."
. ./lib.sh

section "torrent backend"
check_cmd "rtorrent rpc socket exists" test -S /run/rtorrent/rpc.sock

finish

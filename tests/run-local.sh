#!/usr/bin/env bash
#
# On-Pi component checks — run THIS on ahiru (it hits localhost upstreams and
# inspects systemd/filesystem directly, so it needs no basic-auth credentials).
#
#   ssh ahiru.pl 'cd ~/nixos && ./tests/run-local.sh'
#   # or, without deploying, let run-all.sh ship it over for you.
#
# A few checks read calibre's SQLite DBs (world-readable) and one drops to the
# `calibre` user to confirm write access — that one needs passwordless sudo and
# is SKIPped otherwise.

set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

# Mimic what nginx forwards to calibre-web: reverse-proxy auth header + subpath.
CW_HDR=(-H 'X-Remote-User:dan' -H 'X-Script-Name:/books')
BOOKS_DB=/media/data/Books/metadata.db
APP_DB=/var/lib/calibre-web/app.db

# ----------------------------------------------------------------------------
section "systemd units active"
for unit in nginx mpd mympd rtorrent flood calibre-web radicale mcp; do
    check_cmd "$unit" systemctl is-active --quiet "$unit"
done

section "no failed units"
failed=$(systemctl list-units --state=failed --no-legend --plain 2>/dev/null | awk '{print $1}' | paste -sd' ' -)
if [ -z "$failed" ]; then pass "systemctl --failed is empty"; else fail "failed units" "$failed"; fi

# ----------------------------------------------------------------------------
section "calibre-web (:8083) + library"
check_http "index loads" 200 http://127.0.0.1:8083/ "${CW_HDR[@]}"

if command -v sqlite3 >/dev/null 2>&1 && [ -r "$BOOKS_DB" ]; then
    # Library non-empty — regression for the default_language='en' filter that
    # made the UI show zero books.
    nbooks=$(sqlite3 "$BOOKS_DB" 'select count(*) from books;' 2>/dev/null || echo 0)
    if [ "${nbooks:-0}" -gt 0 ]; then pass "library has $nbooks books"; else fail "library is empty"; fi

    # Cover thumbnails serve as images — regression for the srcset/sub_filter
    # bug that 404'd /cover/<id>/sm and left the grid blank.
    book_id=$(sqlite3 "$BOOKS_DB" 'select id from books where has_cover=1 limit 1;' 2>/dev/null)
    if [ -n "$book_id" ]; then
        check_ctype "cover thumbnail is an image" image/jpeg "http://127.0.0.1:8083/cover/$book_id/sm" "${CW_HDR[@]}"
    else
        skip "cover thumbnail" "no book with a cover found"
    fi
else
    skip "library content checks" "sqlite3 or $BOOKS_DB unavailable"
fi

# No calibre-web user pinned to a single book language (the empty-library cause).
if command -v sqlite3 >/dev/null 2>&1 && [ -r "$APP_DB" ]; then
    badlang=$(sqlite3 "$APP_DB" "select count(*) from user where default_language not in ('all','');" 2>/dev/null || echo '?')
    if [ "$badlang" = 0 ]; then pass "no users pinned to a single book language"
    else fail "users with a language filter" "$badlang user(s) have default_language != all"; fi
else
    skip "user language-filter check" "$APP_DB unreadable"
fi

# Write access — calibre-web must be able to edit metadata/covers and accept
# uploads. Needs passwordless sudo to drop to the calibre user.
if sudo -n true 2>/dev/null; then
    if sudo -n -u calibre sh -c "test -w '$BOOKS_DB' && test -w /media/data/Books" 2>/dev/null; then
        pass "calibre can write the library (db + dir)"
    else
        fail "calibre cannot write the library" "check group membership + ACL mask (setfacl)"
    fi
else
    skip "calibre write access" "needs passwordless sudo"
fi

# ----------------------------------------------------------------------------
section "media upstreams (localhost)"
check_up   "mympd (:8080)"       http://127.0.0.1:8080/
check_up   "flood (:3000)"       http://127.0.0.1:3000/
check_up   "radicale (:5232)"    http://127.0.0.1:5232/
check_http "mcp discovery (:3001)" 200 http://127.0.0.1:3001/.well-known/oauth-authorization-server

# ----------------------------------------------------------------------------
section "MPD"
# Greeting on the control port is "OK MPD <version>".
if exec 3<>/dev/tcp/127.0.0.1/6600 2>/dev/null; then
    read -r -t 5 greeting <&3 || greeting=""
    exec 3<&- 3>&-
    case "$greeting" in
        OK\ MPD*) pass "control port :6600 (${greeting%$'\r'})" ;;
        *)        fail "control port :6600" "unexpected greeting '${greeting}'" ;;
    esac
else
    fail "control port :6600" "connection refused"
fi
# The httpd output serves on demand — the port is only bound while MPD has a
# stream. When idle (nothing playing) it's legitimately absent, so SKIP rather
# than FAIL; only assert audio when it's actually listening.
if ss -tln 2>/dev/null | grep -q ':8030 '; then
    check_ctype "HTTP stream :8030 is audio" audio/ http://127.0.0.1:8030/
else
    skip "HTTP stream :8030" "not listening (MPD idle — serves on playback)"
fi

# ----------------------------------------------------------------------------
section "torrent backend"
check_cmd "rtorrent rpc socket exists" test -S /run/rtorrent/rpc.sock

# ----------------------------------------------------------------------------
section "host health"
for mp in / /media/data; do
    use=$(df -P "$mp" 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}')
    if [ -n "$use" ] && [ "$use" -lt 90 ]; then pass "disk $mp at ${use}%"
    else fail "disk $mp at ${use:-?}%" ">= 90% used"; fi
done

# Under-voltage / throttling — the documented cause of Pi wedges. vcgencmd needs
# the `video` group or root, so fall back to sudo and SKIP if neither works.
throttle_raw=""
if vcgencmd get_throttled >/dev/null 2>&1; then
    throttle_raw=$(vcgencmd get_throttled 2>/dev/null)
elif sudo -n vcgencmd get_throttled >/dev/null 2>&1; then
    throttle_raw=$(sudo -n vcgencmd get_throttled 2>/dev/null)
fi
if [ -n "$throttle_raw" ]; then
    thr=${throttle_raw#*=}
    if [ "$thr" = "0x0" ]; then pass "no throttling ($thr)"
    else fail "throttling/under-voltage" "$thr (see /var/log/blackbox)"; fi
else
    skip "throttling check" "vcgencmd needs the video group or sudo"
fi

summary

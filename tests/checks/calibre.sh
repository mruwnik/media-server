#!/usr/bin/env bash
# calibre.sh — calibre-web serves, library is populated, covers render, and the
# service user can write. The library/covers/language checks are regression
# guards for the bugs fixed in 6aade67.
set -uo pipefail
cd "$(dirname "$0")/.."
. ./lib.sh

# Mimic what nginx forwards to calibre-web: reverse-proxy auth header + subpath.
CW_HDR=(-H 'X-Remote-User:dan' -H 'X-Script-Name:/books')
BOOKS_DB=/media/data/Books/metadata.db
APP_DB=/var/lib/calibre-web/app.db

section "calibre-web (:8083) + library"
check_http "index loads" 200 http://127.0.0.1:8083/ "${CW_HDR[@]}"

if command -v sqlite3 >/dev/null 2>&1 && [ -r "$BOOKS_DB" ]; then
    # Library non-empty — regression for the default_language='en' filter.
    nbooks=$(sqlite3 "$BOOKS_DB" 'select count(*) from books;' 2>/dev/null || echo 0)
    if [ "${nbooks:-0}" -gt 0 ]; then pass "library has $nbooks books"; else fail "library is empty"; fi

    # Cover thumbnails serve as images — regression for the srcset/sub_filter bug.
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

# Write access — calibre-web must edit metadata/covers and accept uploads.
if sudo -n true 2>/dev/null; then
    if sudo -n -u calibre sh -c "test -w '$BOOKS_DB' && test -w /media/data/Books" 2>/dev/null; then
        pass "calibre can write the library (db + dir)"
    else
        fail "calibre cannot write the library" "check group membership + ACL mask (setfacl)"
    fi
else
    skip "calibre write access" "needs passwordless sudo"
fi

finish

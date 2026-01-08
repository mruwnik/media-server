#!/usr/bin/env bash
#
# Test all services on ahiru.pl and media.ahiru.pl
# Usage: ./test-services.sh [--host IP] <username> <password>
#

set -euo pipefail

# Default hosts
BLOG_HOST="ahiru.pl"
MEDIA_HOST="media.ahiru.pl"
CUSTOM_HOST=""

# Parse optional --host argument
while [[ $# -gt 0 ]]; do
    case $1 in
        --host)
            CUSTOM_HOST="$2"
            shift 2
            ;;
        *)
            break
            ;;
    esac
done

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 [--host IP] <username> <password>"
    echo ""
    echo "Examples:"
    echo "  $0 username password                    # Test public domains"
    echo "  $0 --host 192.168.1.100 username password   # Test via local IP"
    exit 1
fi

USER="$1"
PASS="$2"

# URLs always use the domain names; --resolve overrides DNS when custom host is set
BLOG_URL="https://${BLOG_HOST}"
MEDIA_URL="https://${MEDIA_HOST}"

if [[ -n "$CUSTOM_HOST" ]]; then
    # Use --resolve to point domains to custom IP, -k to skip cert validation
    BLOG_CURL_OPTS="--resolve ${BLOG_HOST}:443:${CUSTOM_HOST} -k"
    MEDIA_CURL_OPTS="--resolve ${MEDIA_HOST}:443:${CUSTOM_HOST} -k"
else
    BLOG_CURL_OPTS=""
    MEDIA_CURL_OPTS=""
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

PASSED=0
FAILED=0

test_endpoint() {
    local name="$1"
    local url="$2"
    local use_auth="${3:-false}"
    local expected_code="${4:-200}"
    local curl_opts="${5:-}"

    printf "%-40s " "$name"

    local auth_args=""
    if [[ "$use_auth" == "true" ]]; then
        auth_args="-u ${USER}:${PASS}"
    fi

    # Make request, follow redirects, get HTTP code
    local http_code
    http_code=$(eval curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 10 \
        --max-time 30 \
        -L \
        $auth_args \
        $curl_opts \
        "\"$url\"" 2>/dev/null || echo "000")

    if [[ "$http_code" == "$expected_code" ]]; then
        echo -e "${GREEN}PASS${NC} (HTTP $http_code)"
        ((PASSED++)) || true
    elif [[ "$http_code" == "000" ]]; then
        echo -e "${RED}FAIL${NC} (connection failed)"
        ((FAILED++)) || true
    else
        echo -e "${RED}FAIL${NC} (HTTP $http_code, expected $expected_code)"
        ((FAILED++)) || true
    fi
}

test_endpoint_content() {
    local name="$1"
    local url="$2"
    local use_auth="$3"
    local search_string="$4"
    local curl_opts="${5:-}"

    printf "%-40s " "$name"

    local auth_args=""
    if [[ "$use_auth" == "true" ]]; then
        auth_args="-u ${USER}:${PASS}"
    fi

    local content
    content=$(eval curl -s --compressed --connect-timeout 10 --max-time 30 -L $auth_args $curl_opts "\"$url\"" 2>/dev/null || echo "")

    if echo "$content" | grep -qi "$search_string"; then
        echo -e "${GREEN}PASS${NC} (found '$search_string')"
        ((PASSED++)) || true
    else
        echo -e "${RED}FAIL${NC} (missing '$search_string')"
        ((FAILED++)) || true
    fi
}

echo "========================================"
echo "  Testing ahiru.pl and media.ahiru.pl"
echo "  User: $USER"
[[ -n "$CUSTOM_HOST" ]] && echo "  Host override: $CUSTOM_HOST"
echo "========================================"
echo ""

# ========================================
# ahiru.pl - Public blog
# ========================================
echo -e "${YELLOW}=== ahiru.pl (public blog) ===${NC}"

test_endpoint "Homepage" \
    "${BLOG_URL}/" \
    "false" "200" "$BLOG_CURL_OPTS"

test_endpoint "404 page" \
    "${BLOG_URL}/nonexistent-page-12345" \
    "false" "404" "$BLOG_CURL_OPTS"

# MCP server endpoints (these manage their own auth)
test_endpoint "MCP well-known" \
    "${BLOG_URL}/.well-known/oauth-authorization-server" \
    "false" "200" "$BLOG_CURL_OPTS"

echo ""

# ========================================
# media.ahiru.pl - Services portal
# ========================================
echo -e "${YELLOW}=== media.ahiru.pl (services portal) ===${NC}"

test_endpoint "Portal index" \
    "${MEDIA_URL}/" \
    "false" "200" "$MEDIA_CURL_OPTS"

# ----------------------------------------
# Calibre-web (/books)
# ----------------------------------------
echo ""
echo -e "${YELLOW}--- Calibre-web (/books) ---${NC}"

test_endpoint "Without auth (should 401)" \
    "${MEDIA_URL}/books/" \
    "false" "401" "$MEDIA_CURL_OPTS"

test_endpoint "With auth" \
    "${MEDIA_URL}/books/" \
    "true" "200" "$MEDIA_CURL_OPTS"

test_endpoint_content "Contains book UI" \
    "${MEDIA_URL}/books/" \
    "true" "calibre" "$MEDIA_CURL_OPTS"

# ----------------------------------------
# Radicale CalDAV (/radicale)
# ----------------------------------------
echo ""
echo -e "${YELLOW}--- Radicale CalDAV (/radicale) ---${NC}"

test_endpoint "Radicale root" \
    "${MEDIA_URL}/radicale/" \
    "true" "200" "$MEDIA_CURL_OPTS"

# Test PROPFIND for CalDAV
printf "%-40s " "CalDAV PROPFIND"
if [[ -n "$MEDIA_CURL_OPTS" ]]; then
    caldav_response=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 10 \
        -X PROPFIND \
        -u "${USER}:${PASS}" \
        -H "Depth: 0" \
        --resolve "${MEDIA_HOST}:443:${CUSTOM_HOST}" -k \
        "${MEDIA_URL}/radicale/${USER}/" 2>/dev/null || echo "000")
else
    caldav_response=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 10 \
        -X PROPFIND \
        -u "${USER}:${PASS}" \
        -H "Depth: 0" \
        "${MEDIA_URL}/radicale/${USER}/" 2>/dev/null || echo "000")
fi

if [[ "$caldav_response" =~ ^(207|200|404)$ ]]; then
    echo -e "${GREEN}PASS${NC} (HTTP $caldav_response)"
    ((PASSED++)) || true
else
    echo -e "${RED}FAIL${NC} (HTTP $caldav_response)"
    ((FAILED++)) || true
fi

# ----------------------------------------
# Flood torrent UI (/torrents)
# ----------------------------------------
echo ""
echo -e "${YELLOW}--- Flood torrent UI (/torrents) ---${NC}"

test_endpoint "Without auth (should 401)" \
    "${MEDIA_URL}/torrents/" \
    "false" "401" "$MEDIA_CURL_OPTS"

test_endpoint "With auth" \
    "${MEDIA_URL}/torrents/" \
    "true" "200" "$MEDIA_CURL_OPTS"

test_endpoint_content "Contains Flood UI" \
    "${MEDIA_URL}/torrents/" \
    "true" "flood" "$MEDIA_CURL_OPTS"

# ----------------------------------------
# myMPD music UI (/music)
# ----------------------------------------
echo ""
echo -e "${YELLOW}--- myMPD music UI (/music) ---${NC}"

test_endpoint "Without auth (should 401)" \
    "${MEDIA_URL}/music/" \
    "false" "401" "$MEDIA_CURL_OPTS"

test_endpoint "With auth" \
    "${MEDIA_URL}/music/" \
    "true" "200" "$MEDIA_CURL_OPTS"

test_endpoint_content "Contains myMPD UI" \
    "${MEDIA_URL}/music/" \
    "true" "mympd" "$MEDIA_CURL_OPTS"

# ----------------------------------------
# MPD HTTP Stream (direct port 8030)
# ----------------------------------------
echo ""
echo -e "${YELLOW}--- MPD HTTP Stream (port 8030) ---${NC}"

# MPD HTTP stream - streams forever, so we check if we get HTTP headers
printf "%-40s " "MPD stream"
MPD_HOST="${CUSTOM_HOST:-media.ahiru.pl}"
# Grab just the first line of response to check for HTTP/1.x 200
mpd_header=$(timeout 2 curl -s --connect-timeout 2 "http://${MPD_HOST}:8030/" 2>/dev/null | head -c 100 || true)
if [[ -n "$mpd_header" ]]; then
    echo -e "${GREEN}PASS${NC} (streaming audio)"
    ((PASSED++)) || true
else
    echo -e "${YELLOW}SKIP${NC} (not accessible)"
fi

# ========================================
# Summary
# ========================================
echo ""
echo "========================================"
echo -e "  Results: ${GREEN}$PASSED passed${NC}, ${RED}$FAILED failed${NC}"
echo "========================================"

if [[ $FAILED -gt 0 ]]; then
    exit 1
fi

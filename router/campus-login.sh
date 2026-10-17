#!/bin/sh
# ============================================================================
#  campus-login.sh  --  Ruijie ePortal auto-login daemon (pure shell)
#
#  Runs on OpenWrt-like firmware with nothing but curl + sed.
#  No Python, no RSA library, no Node.js required.
#
#  Design notes (all learned the hard way):
#    * queryString MUST be taken from the portal's own interception page.
#      Never synthesise it as wlanuserip=<IP> -- see docs/02.
#    * password is sent in PLAINTEXT when pageInfo says passwordEncrypt=false.
#      See docs/03. If your school returns true, patch do_login() below.
#    * userId / queryString are URL-encoded TWICE (like the portal's own JS).
#    * Host header keeps its capital H (some portals drop lowercase host:).
#    * online test = HTTP 204 AND empty body. Do not rely on ping. See docs/05.
#    * polling interval must stay in the MINUTES, not seconds. See docs/04.
#
#  ASCII-only on purpose: busybox has no locale and mangles non-ASCII bytes.
# ============================================================================

CONF="/etc/storage/campus/campus-login.conf"
if [ -f "$CONF" ]; then
    . "$CONF"
fi

# ---- defaults (override them in the config file) ----
: "${PORTAL_IP:=10.0.0.1}"
: "${ACCOUNT:=YOUR_ACCOUNT}"
: "${PASSWORD:=YOUR_PASSWORD}"
: "${WAN_IF:=eth0}"
: "${INTERVAL:=300}"
: "${PROBE:=http://connectivitycheck.platform.hicloud.com/generate_204}"
: "${PROBE_ALT:=http://www.gstatic.com/generate_204}"
: "${LOG:=/tmp/campus-login.log}"
: "${MAXLOG:=300}"

PORTAL_IP=$(printf '%s' "$PORTAL_IP" | tr -d '\r')
ACCOUNT=$(printf '%s' "$ACCOUNT" | tr -d '\r')
PASSWORD=$(printf '%s' "$PASSWORD" | tr -d '\r')
WAN_IF=$(printf '%s' "$WAN_IF" | tr -d '\r')

LOGIN_URL="http://${PORTAL_IP}/eportal/InterFace.do?method=login"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
    if [ "$(wc -l < "$LOG" 2>/dev/null)" -gt "$MAXLOG" ]; then
        tail -n 150 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
    fi
}

# ---- 1) zero-traffic precondition: pure reads of /sys and /proc ----
link_ready() {
    # if the interface name is wrong, do NOT block -- let the HTTP probe decide
    [ -e "/sys/class/net/$WAN_IF" ] || return 0
    st=$(cat "/sys/class/net/$WAN_IF/operstate" 2>/dev/null)
    [ "$st" = "up" ] || return 1
    grep -q "$WAN_IF" /proc/net/route 2>/dev/null || return 1
    return 0
}

# ---- 2) online test: ONLY 204 + empty body counts as really online ----
http_ok() {
    out=$(curl -s -m 12 -w '\n%{http_code}' "$PROBE" 2>/dev/null)
    code=$(printf '%s' "$out" | tail -n 1)
    body=$(printf '%s' "$out" | sed '$d')
    [ "$code" = "204" ] && [ -z "$body" ] && return 0

    out=$(curl -s -m 12 -w '\n%{http_code}' "$PROBE_ALT" 2>/dev/null)
    code=$(printf '%s' "$out" | tail -n 1)
    body=$(printf '%s' "$out" | sed '$d')
    [ "$code" = "204" ] && [ -z "$body" ]
}

online() {
    link_ready || return 1
    http_ok
}

# ---- 3) URL-encode TWICE, like encodeURIComponent(encodeURIComponent(x)) ----
# '%' must be escaped first in EACH pass, hence the same sed run twice.
_enc1() {
    sed -e 's/%/%25/g' -e 's/@/%40/g' -e 's/&/%26/g' -e 's/=/%3D/g' \
        -e 's/?/%3F/g' -e 's/+/%2B/g' -e 's/ /%20/g' -e 's/:/%3A/g' \
        -e 's|/|%2F|g' -e 's/#/%23/g' -e "s/'/%27/g" -e 's/!/%21/g' \
        -e 's/;/%3B/g' -e 's/,/%2C/g'
}
enc2() {
    printf '%s' "$1" | _enc1 | _enc1
}

# ---- 4) KEY: pull the whole token block out of the portal's redirect page ----
# The portal answers an unauthenticated HTTP request with something like:
#   <script>top.self.location.href='http://PORTAL/eportal/index.jsp?
#       wlanuserip=<32 hex>&wlanacname=..&ssid=..&nasip=..&mac=..&t=..'</script>
get_query_string() {
    page=$(curl -s -m 15 "$PROBE" 2>/dev/null)
    [ -z "$page" ] && page=$(curl -s -m 15 "$PROBE_ALT" 2>/dev/null)

    qs=$(printf '%s' "$page" | sed -n "s|.*index\.jsp?\([^'\"]*\).*|\1|p" | head -1)
    if [ -z "$qs" ]; then
        qs=$(printf '%s' "$page" | sed -n 's/.*\(wlanuserip=[^"'"'"' <>]*\).*/\1/p' | head -1)
    fi
    printf '%s' "$qs"
}

# ---- 5) login ----
do_login() {
    qs_raw=$(get_query_string)
    if [ -z "$qs_raw" ]; then
        log "no queryString captured (portal page not recognised)"
        return 1
    fi

    qs=$(enc2 "$qs_raw")
    uid=$(enc2 "$ACCOUNT")

    # passwordEncrypt=false => the portal expects a PLAINTEXT password (docs/03)
    resp=$(curl -s -m 20 -X POST \
        -H "Host: ${PORTAL_IP}" \
        -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
        -H "Origin: http://${PORTAL_IP}" \
        -H "Referer: http://${PORTAL_IP}/eportal/index.jsp?${qs_raw}" \
        --data-raw "userId=${uid}&password=${PASSWORD}&service=&queryString=${qs}&operatorPwd=&operatorUserId=&validcode=&passwordEncrypt=false" \
        "$LOGIN_URL" 2>/dev/null)

    flat=$(printf '%s' "$resp" | tr -d ' \r\n\t')
    case "$flat" in
        *'"result":"success"'*)
            log "LOGIN OK"
            return 0 ;;
        *)
            log "LOGIN FAILED resp=${flat}"
            return 1 ;;
    esac
}

# ---- main loop ----
log "=== campus-login started (portal=$PORTAL_IP account=$ACCOUNT interval=${INTERVAL}s wan=$WAN_IF) ==="

if ! command -v curl >/dev/null 2>&1; then
    log "FATAL: curl not found"
    exit 1
fi

while true; do
    if online; then
        :                       # online: stay silent, spend nothing
    else
        log "offline -> authenticate"
        do_login
        sleep 5
        if online; then
            log "verified online after login"
        else
            log "still offline after login attempt"
        fi
    fi
    sleep "$INTERVAL"
done

#!/bin/sh
# notify.sh — broadcast a message (read from stdin) to email + Discord.
# Usage:  <something> | notify.sh [subject]
#
# No-op (exit 0) on empty/whitespace stdin — this is what makes a pipeline like
#   diagnostics.sh | notify.sh "ahiru health"
# silent when everything is healthy (diagnostics prints nothing on stdout then).
#
# Channels are independent and each self-guards, so the box can have email,
# Discord, both, or neither. Modelled on maip-server/provision/monitoring/notify.sh.
set -eu

SUBJECT="${1:-ahiru alert}"
log() { logger -t ahiru-notify "$*" 2>/dev/null || true; printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

BODY=$(cat)
if [ -z "$(printf '%s' "${BODY}" | tr -d '[:space:]')" ]; then
    exit 0
fi

# Email address: env wins, else notify_email from /etc/monitoring-config (the
# same file the health-check reads). Parse with yq if present, else a plain grep.
read_cfg_email() {
    [ -f /etc/monitoring-config ] || return 0
    if command -v yq >/dev/null 2>&1; then
        yq -r '.notify_email // empty' /etc/monitoring-config 2>/dev/null
    else
        sed -n 's/^[[:space:]]*notify_email:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' \
            /etc/monitoring-config 2>/dev/null | head -1
    fi
}
ALERT_EMAIL="${NOTIFY_EMAIL:-${MAILTO:-$(read_cfg_email)}}"
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-$(cat /etc/ahiru-discord-webhook 2>/dev/null || true)}"
DISCORD_MAX_CONTENT=1900

email_configured() {
    command -v msmtp >/dev/null 2>&1 || return 1
    [ -f /etc/msmtp.conf ] || [ -f /etc/msmtprc ] || return 1
}
discord_configured() {
    [ -n "${DISCORD_WEBHOOK_URL}" ] || return 1
    command -v curl >/dev/null 2>&1 || return 1
    command -v jq   >/dev/null 2>&1 || return 1
    case "${DISCORD_WEBHOOK_URL}" in https://*) return 0 ;; *) return 1 ;; esac
}

send_email() {
    [ -n "${ALERT_EMAIL}" ] || { log "no notify email configured; skipping email"; return 0; }
    email_configured || { log "WARN: msmtp not configured; skipping email"; return 0; }
    printf 'Subject: %s\nTo: %s\n\n%s\n' "${SUBJECT}" "${ALERT_EMAIL}" "${BODY}" \
        | msmtp "${ALERT_EMAIL}" 2>/dev/null || log "WARN: email send failed"
}

send_discord() {
    discord_configured || { [ -n "${DISCORD_WEBHOOK_URL}" ] && log "WARN: Discord set but curl/jq missing or URL not https; skipping"; return 0; }
    msg="**${SUBJECT}**
\`\`\`
${BODY}
\`\`\`"
    if [ "$(printf '%s' "${msg}" | wc -c)" -le "${DISCORD_MAX_CONTENT}" ]; then
        printf '%s' "${msg}" | jq -Rs '{content: .}' \
            | curl -fsS -m 15 -H 'Content-Type: application/json' -d @- "${DISCORD_WEBHOOK_URL}" >/dev/null 2>&1 \
            || log "WARN: Discord post failed"
        return 0
    fi
    # Too long for one message — post a summary with the full report attached.
    n=$(printf '%s\n' "${BODY}" | grep -c . || true)
    summary=$(printf '**%s**\n%s line(s) — full report attached.' "${SUBJECT}" "${n}")
    payload=$(printf '%s' "${summary}" | jq -Rs '{content: .}')
    tmp=$(mktemp /tmp/ahiru-notify.XXXXXX) || { log "WARN: mktemp failed"; return 0; }
    printf '%s\n' "${BODY}" > "${tmp}"
    curl -fsS -m 20 -F "payload_json=${payload}" \
        -F "files[0]=@${tmp};type=text/markdown;filename=health-report.md" \
        "${DISCORD_WEBHOOK_URL}" >/dev/null 2>&1 || log "WARN: Discord attachment post failed"
    rm -f "${tmp}"
}

send_email
send_discord

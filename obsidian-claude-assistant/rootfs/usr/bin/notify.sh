#!/usr/bin/env bash
# Push a notification to the HA Companion app via the Supervisor proxy.
#
#   notify.sh ask   <tag> <title> <message>   # with Answer / Looks good / Stop
#   notify.sh plain <tag> <title> <message>   # no actions
#
# The tag is what correlates a reply back to a note. Keep it stable across
# rounds so Android replaces the notification instead of stacking a new one.
set -uo pipefail

MODE="${1:?mode required}"
TAG="${2:?tag required}"
TITLE="${3:?title required}"
MESSAGE="${4:?message required}"

# shellcheck source=/dev/null
[ -f /data/env.sh ] && . /data/env.sh

if [ -z "${NOTIFY_SERVICE:-}" ]; then
    echo "[notify] notify_service not configured, skipping: ${TITLE}" >&2
    exit 0
fi

if [ -z "${SUPERVISOR_TOKEN:-}" ]; then
    echo "[notify] SUPERVISOR_TOKEN missing, cannot notify" >&2
    exit 1
fi

# Android caps a notification at 3 actions, so all three have to earn their slot.
if [ "${MODE}" = "ask" ] && [ "${ENABLE_REPLIES:-true}" = "true" ]; then
    ACTIONS='[
      {"action":"REPLY","title":"Answer"},
      {"action":"CLAUDE_OK","title":"Looks good"},
      {"action":"CLAUDE_STOP","title":"Stop asking"}
    ]'
else
    ACTIONS='[]'
fi

PAYLOAD="$(jq -n \
    --arg title "${TITLE}" \
    --arg message "${MESSAGE}" \
    --arg tag "${TAG}" \
    --argjson actions "${ACTIONS}" \
    '{
       title: $title,
       message: $message,
       data: ({ tag: $tag, group: "obsidian-claude-assistant" }
              + (if ($actions | length) > 0 then { actions: $actions } else {} end))
     }')"

HTTP_CODE="$(curl -sS -o /tmp/notify-response -w '%{http_code}' \
    -X POST \
    -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${PAYLOAD}" \
    "http://supervisor/core/api/services/notify/${NOTIFY_SERVICE}")" || {
        echo "[notify] curl failed" >&2
        exit 1
    }

if [ "${HTTP_CODE}" != "200" ]; then
    echo "[notify] HTTP ${HTTP_CODE} from notify.${NOTIFY_SERVICE}: $(cat /tmp/notify-response)" >&2
    exit 1
fi

echo "[notify] sent: ${TITLE}"

#!/usr/bin/env bash
# Push a notification to the HA Companion app via the Supervisor proxy.
#
#   notify.sh ask   <tag> <title> <message>   # with Answer / Looks good / Stop
#   notify.sh plain <tag> <title> <message>   # no actions
#   notify.sh clear <tag>                     # remove one already delivered
#
# The tag is what correlates a reply back to a note. Keep it stable across
# rounds so Android replaces the notification instead of stacking a new one.
set -uo pipefail

MODE="${1:?mode required}"
TAG="${2:?tag required}"
if [ "${MODE}" != "clear" ]; then
    TITLE="${3:?title required}"
    MESSAGE="${4:?message required}"
fi

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

if [ "${MODE}" = "clear" ]; then
    # The counterpart to sticky: an answered question has to be taken down
    # explicitly, or it sits in the shade forever.
    PAYLOAD="$(jq -n --arg tag "${TAG}" \
        '{ message: "clear_notification", data: { tag: $tag } }')"
else
    # Android caps a notification at 3 actions, so all three have to earn their
    # slot. REPLY is a magic name there — it renders a direct-reply field. iOS
    # has no such magic and needs behavior/textInput* instead. Send both; each
    # platform ignores the other's keys.
    if [ "${MODE}" = "ask" ] && [ "${ENABLE_REPLIES:-true}" = "true" ]; then
        ACTIONS='[
          {"action":"REPLY","title":"Answer","behavior":"textInput",
           "textInputButtonTitle":"Send","textInputPlaceholder":"Your answer"},
          {"action":"CLAUDE_OK","title":"Looks good"},
          {"action":"CLAUDE_STOP","title":"Stop asking"}
        ]'
    else
        ACTIONS='[]'
    fi

    # Android only, and only worth it for a question:
    #   sticky      keep the notification when it is selected
    #   clickAction tapping the body does nothing at all
    # Without these a stray tap opens the app AND dismisses the question, which
    # leaves no way to answer it. An error or gave-up notice keeps the default
    # tap-to-open, since there is nothing to answer.
    if [ "${MODE}" = "ask" ]; then
        TAP='{ "sticky": "true", "clickAction": "noAction" }'
    else
        TAP='{}'
    fi

    PAYLOAD="$(jq -n \
        --arg title "${TITLE}" \
        --arg message "${MESSAGE}" \
        --arg tag "${TAG}" \
        --argjson actions "${ACTIONS}" \
        --argjson tap "${TAP}" \
        '{
           title: $title,
           message: $message,
           data: ({ tag: $tag, group: "obsidian-claude-assistant" }
                  + $tap
                  + (if ($actions | length) > 0 then { actions: $actions } else {} end))
         }')"
fi

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

if [ "${MODE}" = "clear" ]; then
    echo "[notify] cleared: ${TAG}"
else
    echo "[notify] sent: ${TITLE}"
fi

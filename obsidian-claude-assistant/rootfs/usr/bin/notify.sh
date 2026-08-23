#!/usr/bin/env bash
# Push a notification to the HA Companion app via the Supervisor proxy.
#
#   notify.sh ask      <tag> <title> <message>   # Answer / Looks good / Stop
#   notify.sh plain    <tag> <title> <message>   # no actions
#   notify.sh clear    <tag>                     # remove one already delivered
#   notify.sh shortcut                           # the ongoing page shortcut
#
# The tag is what correlates a reply back to a note. Keep it stable across
# rounds so Android replaces the notification instead of stacking a new one.
set -uo pipefail

# The shortcut owns one fixed tag, so re-posting it always replaces rather than
# stacks, and web-ui.js can take it down again without knowing how it was built.
SHORTCUT_TAG="obsidian-claude-assistant:shortcut"

MODE="${1:?mode required}"
case "${MODE}" in
    shortcut)
        TAG="${SHORTCUT_TAG}"
        TITLE="Claude Assistant"
        MESSAGE="Open the assistant page"
        ;;
    clear)
        TAG="${2:?tag required}"
        ;;
    *)
        TAG="${2:?tag required}"
        TITLE="${3:?title required}"
        MESSAGE="${4:?message required}"
        ;;
esac

# shellcheck source=/dev/null
[ -f /data/env.sh ] && . /data/env.sh

# The shortcut is opt-in, and pointless without a page to point at: a
# non-dismissible notification whose tap does nothing is worse than none.
if [ "${MODE}" = "shortcut" ]; then
    if [ "${PERSISTENT_SHORTCUT:-false}" != "true" ]; then
        exit 0
    fi
    if [ -z "${INGRESS_PANEL_PATH:-}" ]; then
        echo "[notify] no ingress path resolved, skipping the shortcut" >&2
        exit 0
    fi
fi

if [ -z "${NOTIFY_SERVICE:-}" ]; then
    echo "[notify] notify_service not configured, skipping: ${TITLE:-${TAG}}" >&2
    exit 0
fi

if [ -z "${SUPERVISOR_TOKEN:-}" ]; then
    echo "[notify] SUPERVISOR_TOKEN missing, cannot notify" >&2
    exit 1
fi

if [ "${MODE}" = "clear" ]; then
    # A question answered somewhere other than the notification — the web
    # page, or another device — leaves the notification sitting in the shade
    # with nothing behind it. Take it down explicitly. Harmless when the
    # phone already dropped it: clearing an absent tag is a no-op.
    PAYLOAD="$(jq -n --arg tag "${TAG}" \
        '{ message: "clear_notification", data: { tag: $tag } }')"
elif [ "${MODE}" = "shortcut" ]; then
    # A standing one-tap route to the page, plus one text-input action for
    # capturing a note straight into the inbox without opening anything.
    #
    # persistent needs a tag to hold on to, and sticky as well, or the first
    # tap takes the shortcut away — the one thing it must survive. (Android 14
    # lets it be swiped while unlocked regardless; web-ui.js re-posts it when
    # the page is opened, which is exactly when the phone is in hand.)
    #
    # Its own channel, because importance is fixed when a channel is first
    # created and can never be lowered afterwards: sharing the questions'
    # channel would either make this buzz or permanently mute those. min keeps
    # the shortcut out of the status bar and at the foot of the shade, which is
    # where a permanent fixture belongs.
    #
    # Same REPLY/textInput pair as the "ask" actions below, for the same
    # reason: REPLY is the magic action name Android needs to render a direct-
    # reply field, and iOS instead keys off behavior/textInputButtonTitle.
    # reply-listener.js tells this apart from a note reply by tag, not by
    # action name, so reusing REPLY here is safe.
    if [ "${ENABLE_REPLIES:-true}" = "true" ]; then
        ACTIONS='[
          {"action":"REPLY","title":"Quick capture","behavior":"textInput",
           "textInputButtonTitle":"Save","textInputPlaceholder":"Add to inbox…"}
        ]'
    else
        ACTIONS='[]'
    fi

    PAYLOAD="$(jq -n \
        --arg title "${TITLE}" \
        --arg message "${MESSAGE}" \
        --arg tag "${TAG}" \
        --arg u "${INGRESS_PANEL_PATH}" \
        --argjson actions "${ACTIONS}" \
        '{
           title: $title,
           message: $message,
           data: ({
             tag: $tag,
             group: "obsidian-claude-assistant",
             channel: "Assistant shortcut",
             importance: "min",
             persistent: true,
             sticky: "true",
             notification_icon: "mdi:message-question-outline",
             clickAction: $u,
             url: $u
           } + (if ($actions | length) > 0 then { actions: $actions } else {} end))
         }')"
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

    # Tapping a question opens the add-on's ingress page, where the question
    # is listed with a full reply box and file upload. clickAction is the
    # Android key and url is the iOS one — send both, each platform ignores
    # the other's. Both accept a relative frontend path, and relative is the
    # only correct form: an absolute URL opens the browser, not the app —
    # and it is also what lets the tap work from any network, since the
    # Companion app resolves it against whichever base URL it is currently
    # connected on (internal at home, external away).
    #
    # No sticky here: Android's default is to dismiss on tap, and that is what
    # we want, because the tap lands on the page that lists the question
    # anyway. Losing the notification loses nothing.
    #
    # If the slug lookup failed at startup the path is empty, and there is no
    # page to land on. Then the tap must do nothing at all rather than
    # open-and-dismiss, which would lose the question — noAction plus sticky,
    # so the shade keeps it and the actions stay reachable. An error notice
    # keeps the default tap-to-open-app.
    if [ "${MODE}" = "ask" ]; then
        if [ -n "${INGRESS_PANEL_PATH:-}" ]; then
            TAP="$(jq -n --arg u "${INGRESS_PANEL_PATH}" \
                '{ clickAction: $u, url: $u }')"
        else
            TAP='{ "sticky": "true", "clickAction": "noAction" }'
        fi
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

case "${MODE}" in
    clear)    echo "[notify] cleared: ${TAG}" ;;
    shortcut) echo "[notify] shortcut posted" ;;
    *)        echo "[notify] sent: ${TITLE}" ;;
esac

#!/usr/bin/env bash
# Runs a triage cycle, then waits for the interval OR for the reply listener to
# touch /data/wake — whichever comes first. One code path serves both the timer
# and the instant-reply case.
set -u
# shellcheck source=/dev/null
. /data/env.sh

echo "[loop] started — every ${INTERVAL_MINUTES}m, or immediately on a reply"

# Let Obsidian Sync settle before the first pass.
sleep 15

while true; do
    /usr/bin/triage.sh || echo "[loop] cycle exited non-zero" >&2

    # A usage-limit hold (see triage.sh) ends at a known time. Wake for it
    # rather than up to a full interval later, so the backlog is picked up
    # as soon as the limit resets.
    wait_s=$((INTERVAL_MINUTES * 60))
    until_s="$(jq -r '.until // 0' /data/quota-hold.json 2>/dev/null)"
    case "${until_s}" in ''|*[!0-9]*) until_s=0 ;; esac
    left=$(( until_s - $(date +%s) ))
    if [ "${left}" -gt 0 ] && [ "${left}" -lt "${wait_s}" ]; then
        wait_s=$(( left + 5 ))
    fi

    inotifywait -qq -t "${wait_s}" \
        -e attrib -e close_write /data/wake >/dev/null 2>&1 || true
done

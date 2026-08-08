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
    inotifywait -qq -t "$((INTERVAL_MINUTES * 60))" \
        -e attrib -e close_write /data/wake >/dev/null 2>&1 || true
done

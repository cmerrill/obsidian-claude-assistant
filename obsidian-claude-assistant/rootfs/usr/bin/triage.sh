#!/usr/bin/env bash
# One triage cycle.
#
#   quiesce -> pull -> commit raw capture -> drain replies -> triage -> push -> notify
#
# The raw capture is committed BEFORE Claude touches it, so the original note
# survives in git history even after it is reformatted and moved.
set -uo pipefail

# shellcheck source=/dev/null
. /data/env.sh
# shellcheck source=/usr/bin/vault-git.sh
. /usr/bin/vault-git.sh

STATE=/data
LOCKFILE="${STATE}/triage.lock"
REPLIES="${STATE}/replies.jsonl"
PENDING="${STATE}/replies.processing.jsonl"

log() { echo "[triage] $*"; }
err() { echo "[triage] $*" >&2; }

# A slow cycle must never overlap the next tick.
exec 9>"${LOCKFILE}"
if ! flock -n 9; then
    log "already running, skipping this tick"
    exit 0
fi

cd "${VAULT}" || exit 1

# --- frontmatter helpers -----------------------------------------------------
# Operate only on the first --- block, so body text that happens to look like a
# key is never touched.
#
# Every one of these strips a trailing CR. The vault is edited from Windows
# Obsidian as well as from here, so a note can arrive with CRLF endings — and
# an unstripped "true\r" would never compare equal to "true", which would mean
# flagged notes silently never getting a notification.

fm_get() {
    awk -v key="$2" '
        { sub(/\r$/, "") }
        NR==1 && $0=="---" { infm=1; next }
        infm && $0=="---"  { exit }
        infm {
            k=$0; sub(/:.*/,"",k); gsub(/^[ \t]+|[ \t]+$/,"",k)
            if (k==key) { v=$0; sub(/^[^:]*:[ \t]*/,"",v); gsub(/^"|"$/,"",v); print v; exit }
        }
    ' "$1"
}

fm_drop() {
    local file="$1"; shift
    local tmp; tmp="$(mktemp)"
    awk -v keys="$*" '
        BEGIN { n=split(keys,K," "); for(i=1;i<=n;i++) drop[K[i]]=1 }
        NR==1 && $0=="---" { infm=1; print; next }
        infm && $0=="---"  { infm=0; print; next }
        infm {
            k=$0; sub(/:.*/,"",k); gsub(/^[ \t]+|[ \t]+$/,"",k)
            if (k in drop) next
        }
        { print }
    ' "${file}" > "${tmp}" && mv "${tmp}" "${file}"
}

fm_set() {
    local file="$1" key="$2" value="$3"
    local tmp; tmp="$(mktemp)"
    awk -v key="${key}" -v value="${value}" '
        NR==1 && $0=="---" { infm=1; print; next }
        infm && $0=="---"  { if (!done) print key ": " value; infm=0; done=1; print; next }
        infm {
            k=$0; sub(/:.*/,"",k); gsub(/^[ \t]+|[ \t]+$/,"",k)
            if (k==key) { print key ": " value; done=1; next }
        }
        { print }
    ' "${file}" > "${tmp}" && mv "${tmp}" "${file}"
}

# The last question in the transcript, trimmed to fit a notification.
#
# A question is a `- **Qn** …` list item, and markdown wraps: Claude or an
# editor may hard-wrap one across several physical lines with the remainder
# indented under the marker. Read those continuation lines too — matching only
# the marker line drops the tail silently, and the tail is usually where the
# actual question lives. A blank line, a new list item, a heading, or a rule
# ends it.
#
# Android's Companion app renders the message with BigTextStyle, but the shade
# caps the expanded view around 430 bytes (~10 lines) and cuts what is past it
# with no indication there was more. Cap here at that same length instead, so
# the truncation shows up as an explicit ellipsis rather than a sentence that
# just stops. Trim back to a word boundary so a cut never lands inside a
# multi-byte character — jq needs valid UTF-8, and both ${#q} and `cut -c` count
# bytes under the container's C locale.
# awk rather than `grep -oP`: PCRE is unavailable under some locales.
last_question() {
    local q head
    q="$(awk '
        { sub(/\r$/, "") }
        /^- \*\*Q[0-9]+\*\*/ {
            line = $0
            sub(/^- \*\*Q[0-9]+\*\*[ \t]*/, "", line)
            q = line; cap = 1; next
        }
        cap {
            if ($0 ~ /^[ \t]*$/ || $0 ~ /^[ \t]*([-*+]|[0-9]+\.)[ \t]/ \
                || $0 ~ /^#/ || $0 ~ /^---/) { cap = 0; next }
            t = $0; sub(/^[ \t]+/, "", t); q = q " " t
        }
        END { print q }
    ' "$1" 2>/dev/null)"

    if [ "${#q}" -le 430 ]; then
        printf '%s' "${q}"
        return
    fi

    # Drop the partial trailing word; falls back to the hard cut when there is
    # no space to trim back to.
    head="$(printf '%s' "${q}" | cut -c1-429)"
    case "${head}" in
        *' '*) head="${head% *}" ;;
    esac
    printf '%s…' "${head}"
}

# Notes still awaiting an answer, excluding ones the user told us to drop.
#
# grep only narrows the candidate list — .claude/commands and templates/ both
# contain that literal string as documentation. fm_get is the actual test,
# because it reads the first --- block and nothing else.
flagged_notes() {
    grep -rlF --include='*.md' \
        --exclude-dir=.git --exclude-dir=.claude --exclude-dir=templates \
        'needs-review: true' . 2>/dev/null \
        | sed 's|^\./||; s|\r$||' \
        | while read -r f; do
            [ "$(fm_get "${f}" 'needs-review')" = "true" ] || continue
            [ "$(fm_get "${f}" 'review-stopped')" = "true" ] && continue
            echo "${f}"
        done
}

json_get() { jq -r --arg k "$2" '.[$k] // empty' "$1" 2>/dev/null; }
json_set() {
    local file="$1" k="$2" v="$3" tmp
    tmp="$(mktemp)"
    jq --arg k "${k}" --arg v "${v}" '.[$k] = $v' "${file}" > "${tmp}" && mv "${tmp}" "${file}"
}
json_del() {
    local file="$1" k="$2" tmp
    tmp="$(mktemp)"
    jq --arg k "${k}" 'del(.[$k])' "${file}" > "${tmp}" && mv "${tmp}" "${file}"
}

# --- claude ------------------------------------------------------------------
# Never pass --bare: it skips CLAUDE.md, skips .claude/commands, and ignores the
# subscription login. All three are load-bearing here.
#
# AskUserQuestion is denied deterministically rather than by prompt text alone.
# Nobody is watching a background run, and in testing the model reached for it
# anyway and then abandoned the batch. Denying it at the CLI is the only
# reliable guard; the command file tells it to keep going after a denial.

# Filing notes needs a small, nameable set of tools, so the default is an
# allowlist rather than bypassing permissions outright. The container is the
# outer boundary; this is the inner one. Anything the model reaches for that is
# not on the list is refused and logged, instead of simply running.
#
# acceptEdits covers Write/Edit and the common filesystem commands, but not
# network calls or deletion, so those are named explicitly.
#
# There is deliberately no `rm` rule. Deletion goes through inbox-done.sh, which
# resolves the path and refuses anything that is not a regular .md file sitting
# directly in inbox/. A rule like Bash(rm inbox/*) only matches a string prefix,
# so quoting or a crafted path defeats it; the script checks the real location.
CLAUDE_TOOLS="Read,Glob,Grep,WebFetch,WebSearch,Bash(geocode.sh *),Bash(inbox-done.sh *),Bash(ls *)"

claude_flags() {
    if [ "${PERMISSION_MODE:-allowlist}" = "bypass" ]; then
        printf '%s\0' --dangerously-skip-permissions
    else
        printf '%s\0' --permission-mode acceptEdits --allowedTools "${CLAUDE_TOOLS}"
    fi
    printf '%s\0' --disallowedTools "AskUserQuestion,Skill"
    printf '%s\0' --model "${MODEL}" --output-format json
}

run_claude() {
    local prompt="$1" resume="${2:-}" out rc
    local -a flags=()
    mapfile -d '' -t flags < <(claude_flags)
    out="$(mktemp)"

    if [ -n "${resume}" ]; then
        claude -p "${prompt}" --resume "${resume}" "${flags[@]}" > "${out}" 2>/dev/null
        rc=$?
        if [ ${rc} -ne 0 ]; then
            log "resume of session ${resume} failed, starting fresh"
            resume=""
        fi
    fi

    if [ -z "${resume}" ]; then
        claude -p "${prompt}" "${flags[@]}" > "${out}"
        rc=$?
    fi

    cp "${out}" "${STATE}/last-run.json"

    # Surface refusals. A tool the prompt legitimately needs shows up here, and
    # is the signal to widen CLAUDE_TOOLS rather than to bypass permissions.
    local denied
    denied="$(jq -r '[.permission_denials[]?.tool_name] | unique | join(", ")' "${out}" 2>/dev/null)"
    [ -n "${denied}" ] && log "tools refused this run: ${denied}"

    if [ ${rc} -ne 0 ]; then
        err "claude exited ${rc}"
        rm -f "${out}"
        return ${rc}
    fi

    CLAUDE_RESULT="$(jq -r '.result // empty' "${out}")"
    CLAUDE_SESSION="$(jq -r '.session_id // empty' "${out}")"
    rm -f "${out}"
    return 0
}

# --- 1. wait for the vault to stop moving ------------------------------------
# Do not triage a file Obsidian Sync is still writing. `ob sync-status` output
# is logged for humans; quiescence is decided from mtimes, which cannot drift
# out of sync with a CLI's output format.

ob sync-status --path "${VAULT}" 2>/dev/null | sed 's/^/[triage] sync-status: /' || true

for _ in $(seq 1 36); do
    if [ -z "$(find "${VAULT}" -path "${VAULT}/.git" -prune -o -type f -newermt '-10 seconds' -print -quit 2>/dev/null)" ]; then
        break
    fi
    log "vault still settling"
    sleep 5
done

# --- 2. pull, then preserve the raw capture ----------------------------------

vault_pull || err "pull failed, continuing with local state"
vault_commit_and_push "Sync: inbound from Obsidian" || true

# --- 3. drain replies --------------------------------------------------------

REPLIES_HANDLED=0

# Recover a batch a previous cycle claimed but never finished. PENDING only
# exists here if a run died between the claim below and its own `rm` — a
# container reset mid-drain, say. Those answers were already delivered by the
# phone, so fold them back onto the live queue instead of stranding them (or
# letting the claim below clobber the file). Append rather than rewrite REPLIES,
# so a reply the listener is writing this instant can't be lost to the move.
if [ -s "${PENDING}" ]; then
    log "recovering replies from an interrupted cycle"
    cat "${PENDING}" >> "${REPLIES}"
    rm -f "${PENDING}"
fi

if [ -s "${REPLIES}" ]; then
    # Claim the queue atomically; the listener keeps appending to a fresh file.
    mv "${REPLIES}" "${PENDING}"
    : > "${REPLIES}"

    # Group by note. Two answers sent before the loop woke become one call.
    jq -s -c '
        map(select(.note != null))
        | group_by(.note)[]
        | { note: .[0].note,
            actions: [.[].action],
            replies: [.[] | select(.reply_text != null and .reply_text != "") | .reply_text] }
    ' "${PENDING}" 2>/dev/null | while IFS= read -r group; do
        note="$(jq -r '.note' <<<"${group}")"
        actions="$(jq -r '.actions | join(" ")' <<<"${group}")"

        if [ ! -f "${VAULT}/${note}" ]; then
            err "reply for missing note ${note}, dropping"
            continue
        fi

        # The question notification is sticky, so pressing an action leaves it
        # on screen. Take it down now that it has been answered. A follow-up
        # round sends a fresh one under the same tag.
        /usr/bin/notify.sh clear "obsidian-claude-assistant:${note}" || true

        # Precedence: stop beats a reply, a reply beats a bare acknowledgement.
        if [[ "${actions}" == *CLAUDE_STOP* ]]; then
            log "${note}: stop asking"
            fm_set "${note}" 'review-stopped' 'true'
            json_del "${STATE}/notified.json" "${note}"

        elif [[ "${actions}" == *REPLY* ]]; then
            texts="$(jq -r '.replies | join(" | ")' <<<"${group}")"
            log "${note}: applying reply"
            session="$(json_get "${STATE}/threads.json" "${note}")"
            if run_claude "/resolve-review ${note} — replies in order: ${texts}" "${session}"; then
                echo "${CLAUDE_RESULT}" | sed 's/^/[triage] /'
                [ -n "${CLAUDE_SESSION}" ] && json_set "${STATE}/threads.json" "${note}" "${CLAUDE_SESSION}"
            else
                /usr/bin/notify.sh plain "obsidian-claude-assistant:error" \
                    "Triage error" "Couldn't apply your reply to ${note}. Check the add-on log."
            fi

        elif [[ "${actions}" == *CLAUDE_OK* ]]; then
            # Deterministic: no Claude call, no tokens.
            log "${note}: confirmed, clearing flag"
            fm_drop "${note}" 'needs-review' 'review-round'
            json_del "${STATE}/notified.json" "${note}"
            json_del "${STATE}/threads.json" "${note}"
        fi
    done

    rm -f "${PENDING}"
    REPLIES_HANDLED=1
    vault_commit_and_push "Review: applied replies" || true
fi

# --- 4. triage the inbox -----------------------------------------------------
# Only file a note that has stopped changing. Obsidian Sync pushes a capture as
# it is typed, so a note touched seconds ago may be half-written — and triaging
# it would file the fragment, then delete the file before the rest arrives.
#
# Age is measured from mtime, which is the last write from any source. Keep
# typing and the note simply waits for the next cycle. A note that arrives by
# git pull gets a fresh mtime too, so it also waits one settle window.
#
# The step-1 quiesce loop is a different guard: it waits for the vault as a
# whole to go quiet, and proceeds anyway once it times out. This one is per file
# and does not give up.

shopt -s nullglob
INBOX_FILES=("${VAULT}"/inbox/*.md)
shopt -u nullglob

SETTLE_MIN="${INBOX_SETTLE_MINUTES:-2}"
NOW="$(date +%s)"

READY=()
WAITING=0
for f in "${INBOX_FILES[@]}"; do
    mtime="$(stat -c %Y "${f}" 2>/dev/null)"
    if [ -z "${mtime}" ] || [ $(( NOW - mtime )) -lt $(( SETTLE_MIN * 60 )) ]; then
        log "$(basename "${f}"): edited within ${SETTLE_MIN}m, waiting for it to settle"
        WAITING=$(( WAITING + 1 ))
        continue
    fi
    READY+=("${f}")
done

if [ ${#READY[@]} -eq 0 ]; then
    [ "${REPLIES_HANDLED}" -eq 0 ] && [ "${WAITING}" -eq 0 ] && log "inbox empty, nothing to do"
else
    # Name the eligible notes in the prompt. The vault-side command globs inbox/
    # on its own, and would otherwise pick up the ones still settling.
    names="$(printf '%s, ' "${READY[@]##*/}")"
    names="${names%, }"

    log "triaging ${#READY[@]} note(s): ${names}"
    if run_claude "/triage-inbox — process only these notes, and ignore any other file in inbox/: ${names}"; then
        echo "${CLAUDE_RESULT}" | sed 's/^/[triage] /'
        vault_commit_and_push "Triage: ${#READY[@]} note(s) from inbox" || true
    else
        /usr/bin/notify.sh plain "obsidian-claude-assistant:error" \
            "Triage failed" "Claude exited non-zero on ${#READY[@]} inbox note(s). Check the add-on log."
        # Leave the files in place; the stuck counter below decides when to give up.
    fi
fi

# --- 5. stuck files ----------------------------------------------------------
# A malformed note that survives every run would otherwise burn tokens forever.
#
# Only the notes offered to Claude this cycle can be counted. A note still
# settling was never attempted, and three quick edits must not park it.
# Anything filed successfully is already gone, so it drops out here.

STUCK_NOTIFIED=0
for f in "${READY[@]}"; do
    [ -f "${f}" ] || continue
    base="$(basename "${f}")"
    count="$(json_get "${STATE}/attempts.json" "${base}")"
    count=$(( ${count:-0} + 1 ))

    if [ "${count}" -ge 3 ]; then
        log "${base}: stuck after 3 attempts, moving to inbox/stuck/"
        mkdir -p "${VAULT}/inbox/stuck"
        git_v mv "inbox/${base}" "inbox/stuck/${base}" 2>/dev/null \
            || mv "${f}" "${VAULT}/inbox/stuck/${base}"
        json_del "${STATE}/attempts.json" "${base}"
        /usr/bin/notify.sh plain "obsidian-claude-assistant:stuck:${base}" \
            "Gave up on ${base}" "Failed 3 triage attempts. Moved to inbox/stuck/."
        STUCK_NOTIFIED=1
    else
        json_set "${STATE}/attempts.json" "${base}" "${count}"
    fi
done

[ "${STUCK_NOTIFIED}" -eq 1 ] && vault_commit_and_push "Triage: park stuck notes" || true

# --- 6. prune stale state ----------------------------------------------------
# Resolving a note often renames it — "the georgian place" becomes cheeseboat.md.
# Drop keys for notes that are gone or no longer flagged, so these files do not
# grow without bound.

prune_state() {
    local file="$1" key keys
    # Read every key up front: json_del rewrites this same file inside the loop.
    keys="$(jq -r 'keys[]' "${file}" 2>/dev/null)"
    [ -z "${keys}" ] && return 0
    while IFS= read -r key; do
        key="${key%$'\r'}"
        [ -z "${key}" ] && continue
        if [ ! -f "${VAULT}/${key}" ] || [ "$(fm_get "${VAULT}/${key}" 'needs-review')" != "true" ]; then
            json_del "${file}" "${key}"
        fi
    done <<< "${keys}"
}

prune_state "${STATE}/notified.json"
prune_state "${STATE}/threads.json"

# --- 7. ask about anything still flagged -------------------------------------
# notified.json records "<round>@<epoch>": the round we last pinged about, and
# when. The round stops an unchanged note pinging twice; the timestamp lets an
# unanswered question come back.
#
# A notification is easy to lose — a stray tap used to open the app and dismiss
# it, a swipe still does, and a phone that was off never saw it. Without a
# re-ask the note stays flagged in the vault and is never mentioned again.
#
# Two things to know about the timer: a re-ask spends one of the
# MAX_NOTIFICATIONS slots for the cycle, and the delay rounds up to the next
# interval_minutes tick, because this section only runs inside a cycle.

[ "${NOTIFY_ON}" = "errors" ] && exit 0

RENOTIFY_AFTER_MINUTES="${RENOTIFY_AFTER_MINUTES:-60}"
now="$(date +%s)"

sent=0
while IFS= read -r note; do
    [ -z "${note}" ] && continue
    [ "${sent}" -ge "${MAX_NOTIFICATIONS}" ] && break

    round="$(fm_get "${note}" 'review-round')"
    round="${round:-1}"

    # A value with no @ predates the timer. Treat it as never-timestamped, so
    # each still-open question is re-asked once after the upgrade.
    prev="$(json_get "${STATE}/notified.json" "${note}")"
    case "${prev}" in
        *@*) prev_round="${prev%@*}"; prev_ts="${prev##*@}" ;;
        *)   prev_round="${prev}";    prev_ts=0 ;;
    esac
    case "${prev_ts}" in ''|*[!0-9]*) prev_ts=0 ;; esac

    repeat=0
    if [ -n "${prev_round}" ] && [ "${prev_round}" = "${round}" ]; then
        # Already given up on this one — say it once, then leave it alone.
        [ "${round}" -ge "${MAX_REVIEW_ROUNDS}" ] && continue
        [ "${RENOTIFY_AFTER_MINUTES}" -eq 0 ] && continue
        [ $(( now - prev_ts )) -lt $(( RENOTIFY_AFTER_MINUTES * 60 )) ] && continue
        repeat=1
    fi

    question="$(last_question "${note}")"
    [ -z "${question}" ] && question="Needs a look — no question recorded."

    # Diagnostic: how much question text we actually hand to the notification.
    # If this is well under the note's real question, the loss is on our side
    # (line-based extraction); if it matches but the phone shows less, the shade
    # is capping the expanded height and the rest is simply not rendered.
    log "${note}: notifying with ${#question}-char question"

    name="$(basename "${note}" .md)"
    if [ "${round}" -ge "${MAX_REVIEW_ROUNDS}" ]; then
        /usr/bin/notify.sh plain "obsidian-claude-assistant:${note}" \
            "Gave up: ${name}" "${question}"
    elif [ "${repeat}" -eq 1 ]; then
        /usr/bin/notify.sh ask "obsidian-claude-assistant:${note}" \
            "${name} (round ${round}, still waiting)" "${question}"
    else
        /usr/bin/notify.sh ask "obsidian-claude-assistant:${note}" \
            "${name} (round ${round})" "${question}"
    fi

    json_set "${STATE}/notified.json" "${note}" "${round}@${now}"
    sent=$(( sent + 1 ))
done < <(flagged_notes)

[ "${sent}" -gt 0 ] && log "asked about ${sent} note(s)"

exit 0

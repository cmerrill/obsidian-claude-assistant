#!/usr/bin/env bash
# One triage cycle.
#
#   quiesce -> pull -> commit raw capture -> drain replies -> triage
#           -> sweep finished todos -> push -> notify
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

# --- rewriting a file in place -----------------------------------------------
# Every rewriter below — frontmatter and JSON alike — builds the new version in
# a tempfile. That tempfile must never be renamed over the target: mktemp
# creates at 0600, and mv carries the mode with it. For a vault note that turns
# 644 into 600, so the Samba, SSH, and File editor add-ons quietly lose read
# access to exactly the notes you interact with most — one flagged note at a
# time, with nothing on screen to say why.
#
# Writing through the existing file keeps its mode, its owner, and its inode.
# Nothing is given up by doing so: /tmp is the container's own layer and the
# vault is a bind mount from the host, so the mv this replaces was already a
# copy onto a truncated destination, not an atomic rename.
#
# todo-sweep.sh writes through the target for the same reason. It is a separate
# script and cannot share this function.
replace_file() {
    local tmp="$1" file="$2"
    cat "${tmp}" > "${file}" || { rm -f "${tmp}"; return 1; }
    rm -f "${tmp}"
}

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
    ' "${file}" > "${tmp}" && replace_file "${tmp}" "${file}"
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
    ' "${file}" > "${tmp}" && replace_file "${tmp}" "${file}"
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
    jq --arg k "${k}" --arg v "${v}" '.[$k] = $v' "${file}" > "${tmp}" && replace_file "${tmp}" "${file}"
}
json_del() {
    local file="$1" k="$2" tmp
    tmp="$(mktemp)"
    jq --arg k "${k}" 'del(.[$k])' "${file}" > "${tmp}" && replace_file "${tmp}" "${file}"
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
                # The shared :done tag makes completion notices replace each
                # other instead of stacking up in the shade.
                [ "${NOTIFY_ON}" = "always" ] && /usr/bin/notify.sh plain \
                    "obsidian-claude-assistant:done" "Applied your reply" "${note}" || true
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
    base="$(basename "${f}")"

    # inbox/.gitkeep is what keeps the folder in the repo once the last capture
    # has been filed — git does not track empty directories. The *.md glob above
    # already excludes it twice over (wrong extension, and bash does not match
    # dotfiles without dotglob); this is the explicit statement, so widening that
    # glob later cannot quietly hand a dotfile to Claude as if it were a note.
    case "${base}" in .*) continue ;; esac

    mtime="$(stat -c %Y "${f}" 2>/dev/null)"
    if [ -z "${mtime}" ] || [ $(( NOW - mtime )) -lt $(( SETTLE_MIN * 60 )) ]; then
        log "${base}: edited within ${SETTLE_MIN}m, waiting for it to settle"
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
        [ "${NOTIFY_ON}" = "always" ] && /usr/bin/notify.sh plain \
            "obsidian-claude-assistant:done" "Filed ${#READY[@]} note(s)" "${names}" || true
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

# --- 6. sweep finished todos -------------------------------------------------
# Ticking a box in Obsidian leaves the item sitting in "## Tasks", so a long
# list slowly fills up with things that are already done. Move the finished
# top-level ones down to "## Done".
#
# Runs after the inbox pass on purpose: an item filed this cycle and already
# ticked gets swept in the same run rather than waiting for the next one.
#
# Deterministic shell, not a Claude call — see todo-sweep.sh for why. It costs
# nothing on a cycle where nothing was ticked, which is most of them.

SWEEP_RC=0
/usr/bin/todo-sweep.sh || SWEEP_RC=$?
case "${SWEEP_RC}" in
    0) vault_commit_and_push "Todo: move finished tasks to Done" || true ;;
    1) ;;  # nothing was ticked since the last sweep
    *) err "todo sweep exited ${SWEEP_RC}" ;;
esac

# --- 7. prune stale state ----------------------------------------------------
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

# --- 7b. delete processed ephemeral attachments ------------------------------
# Files uploaded through the web page with "delete after processing" ticked.
# ephemeral.json maps an owner note to the files it brought along; once the
# owner is dealt with, the files have served their purpose.
#
# Deterministic shell, like todo-sweep — deletion is not a job to hand the
# model, and inbox-done.sh deliberately cannot touch attachments/. An owner is
# done when its note is gone (capture filed and removed), unflagged (question
# resolved or confirmed), or review-stopped (user said stop). A note still
# mid-conversation keeps its files: a later round may still need them.

cleanup_ephemeral() {
    local owners owner files f base target resolved_dir att_dir
    EPHEMERAL_DELETED=0
    owners="$(jq -r 'keys[]' "${STATE}/ephemeral.json" 2>/dev/null)"
    [ -z "${owners}" ] && return 0
    att_dir="$(cd "${VAULT}/attachments" 2>/dev/null && pwd -P)" || return 0

    while IFS= read -r owner; do
        owner="${owner%$'\r'}"
        [ -z "${owner}" ] && continue

        if [ -f "${VAULT}/${owner}" ]; then
            [ "$(fm_get "${VAULT}/${owner}" 'needs-review')" = "true" ] \
                && [ "$(fm_get "${VAULT}/${owner}" 'review-stopped')" != "true" ] \
                && continue
        else
            # A capture parked in inbox/stuck/ was never processed — its
            # attachment is still the only copy of whatever it carried.
            case "${owner}" in
                inbox/*)
                    [ -f "${VAULT}/inbox/stuck/$(basename "${owner}")" ] && continue
                    ;;
            esac
        fi

        # Same discipline as inbox-done.sh: constrain the name, then check
        # where the path really resolves before rm.
        files="$(jq -r --arg k "${owner}" '.[$k][]?' "${STATE}/ephemeral.json" 2>/dev/null)"
        while IFS= read -r f; do
            f="${f%$'\r'}"
            case "${f}" in attachments/*) ;; *) continue ;; esac
            base="${f#attachments/}"
            case "${base}" in */*|.*|"") continue ;; esac
            target="${VAULT}/attachments/${base}"
            { [ -f "${target}" ] && [ ! -L "${target}" ]; } || continue
            resolved_dir="$(cd "$(dirname "${target}")" && pwd -P)"
            [ "${resolved_dir}" = "${att_dir}" ] || continue
            if rm -- "${target}"; then
                log "cleanup: removed ${f} (${owner} is done)"
                EPHEMERAL_DELETED=1
            fi
        done <<< "${files}"

        json_del "${STATE}/ephemeral.json" "${owner}"
    done <<< "${owners}"
}

if [ -f "${STATE}/ephemeral.json" ]; then
    cleanup_ephemeral
    [ "${EPHEMERAL_DELETED}" -eq 1 ] && vault_commit_and_push "Cleanup: removed processed attachments" || true
fi

# --- 8. ask about anything still flagged -------------------------------------
# One notification per round, and that is all. The web page is the durable
# record of open questions — a dismissed, swiped, or never-seen notification
# costs nothing, because the question stays on the page until it is answered.
# Rounds only advance when a reply is processed, so once-per-round is
# naturally finite: no re-ask timer, no give-up cap. (Both used to exist,
# solely because a lost notification once meant a lost question.)
#
# notified.json still records "<round>@<epoch>". Nothing reads the epoch any
# more, but keeping the format means no state migration on upgrade and a
# clean rollback.

[ "${NOTIFY_ON}" = "errors" ] && exit 0

now="$(date +%s)"

sent=0
while IFS= read -r note; do
    [ -z "${note}" ] && continue
    [ "${sent}" -ge "${MAX_NOTIFICATIONS}" ] && break

    round="$(fm_get "${note}" 'review-round')"
    round="${round:-1}"

    # Strip the epoch if present; pre-upgrade values without one compare as-is.
    prev="$(json_get "${STATE}/notified.json" "${note}")"
    prev_round="${prev%@*}"
    [ -n "${prev_round}" ] && [ "${prev_round}" = "${round}" ] && continue

    question="$(last_question "${note}")"
    [ -z "${question}" ] && question="Needs a look — no question recorded."

    # Diagnostic: how much question text we actually hand to the notification.
    # If this is well under the note's real question, the loss is on our side
    # (line-based extraction); if it matches but the phone shows less, the shade
    # is capping the expanded height and the rest is simply not rendered.
    log "${note}: notifying with ${#question}-char question"

    name="$(basename "${note}" .md)"
    /usr/bin/notify.sh ask "obsidian-claude-assistant:${note}" \
        "${name} (round ${round})" "${question}"

    json_set "${STATE}/notified.json" "${note}" "${round}@${now}"
    sent=$(( sent + 1 ))
done < <(flagged_notes)

[ "${sent}" -gt 0 ] && log "asked about ${sent} note(s)"

exit 0

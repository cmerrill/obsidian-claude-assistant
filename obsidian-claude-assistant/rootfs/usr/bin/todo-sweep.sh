#!/usr/bin/env bash
# Move finished top-level tasks out of "## Tasks" and into "## Done", for every
# note in todo/.
#
# This is shell and not a Claude call on purpose. The work is mechanical, it
# runs on every cycle whether or not anything was ticked, and the task text
# survives byte-for-byte instead of being retyped by a model. An empty sweep
# costs nothing, which is the same bargain the rest of the loop makes.
#
# The rules come from the vault's CLAUDE.md:
#
#   * Only a TOP-LEVEL "- [x]" moves. A checked subtask under an unchecked
#     parent stays exactly where it is — the parent is what "done" is about.
#   * A moved task takes its indented children with it, and any child still
#     unchecked is checked on the way out. Ticking the parent is the statement
#     that the whole thing is finished.
#   * "## Done" is created only when there is something to put in it, directly
#     after "## Tasks" — so "## Notes" stays last.
#   * "status" is never touched. A shopping list whose "## Tasks" is empty is
#     still open; deciding a todo note is finished stays a human's call.
#   * A note with no "## Tasks" section is a single task, and is left alone.
#
# Exit status: 0 if something moved, 1 if there was nothing to do, 2 on error.
# The caller uses that to decide whether a commit is worth making.
set -uo pipefail

VAULT="${VAULT:-$(pwd)}"
TODO_DIR="${VAULT}/todo"

# A note is left alone until it has stopped changing, for the same reason inbox
# captures are: Obsidian Sync writes a file while it is still being edited, and
# rewriting one under a live editor invites a sync conflict over a cosmetic
# change. Reuses inbox_settle_minutes rather than adding a second knob that
# would always be set to the same value.
SETTLE_MIN="${INBOX_SETTLE_MINUTES:-2}"

log() { echo "[sweep] $*"; }

[ -d "${TODO_DIR}" ] || { log "no todo/ folder, nothing to sweep"; exit 1; }

shopt -s nullglob
FILES=("${TODO_DIR}"/*.md)
shopt -u nullglob

[ ${#FILES[@]} -eq 0 ] && { log "todo/ is empty"; exit 1; }

# The awk below rewrites one note and reports how many top-level tasks it moved.
#
# Interval expressions ({1,6}) are avoided throughout — mawk is the awk in this
# image and its support for them is not something to rely on.
read -r -d '' SWEEP_AWK <<'AWK'
function is_top_done(s)   { return s ~ /^[-*+] \[[xX]\]/ }
function is_child(s)      { return s ~ /^[ \t]+[^ \t]/ }
function is_blank(s)      { return s ~ /^[ \t]*$/ }
function is_heading(s)    { return s ~ /^#+[ \t]/ }
function is_h2(s, word)   { return tolower(s) ~ "^##[ \t]+" word "[ \t]*$" }

# Section bodies are plain lists here, so normalising the blank lines around
# them is safe and keeps a swept note looking hand-written: no leading or
# trailing gap, never two blank lines in a row.
function tidy(src, cnt, dst,   i, m, gap) {
    m = 0; gap = 0
    for (i = 1; i <= cnt; i++) {
        if (is_blank(src[i])) { gap = 1; continue }
        if (gap && m > 0) dst[++m] = ""
        gap = 0
        dst[++m] = src[i]
    }
    return m
}

# Where the section starting at `start` ends: the next heading, or past the end.
function section_end(start,   i) {
    for (i = start + 1; i <= n; i++) if (is_heading(L[i])) return i
    return n + 1
}

{
    line = $0
    # The vault is edited from Windows Obsidian too, so a note can arrive with
    # CRLF endings. Strip for matching, and put them back on the way out rather
    # than silently reformatting the whole file.
    if (sub(/\r$/, "", line)) crlf = 1
    L[++n] = line
}

END {
    if (crlf) ORS = "\r\n"

    # Skip the frontmatter, so a "## Done" written inside a fenced block in
    # "## Notes" is the only false positive left, not a YAML value as well.
    body = 1
    if (n >= 1 && L[1] == "---") {
        for (i = 2; i <= n; i++) if (L[i] == "---") { body = i + 1; break }
    }

    for (i = body; i <= n; i++) {
        if (!tasks && is_h2(L[i], "tasks"))     tasks = i
        else if (!done && is_h2(L[i], "done"))  done = i
    }

    # No "## Tasks" means a single-task note. Nothing to sweep, and giving it
    # sections would turn it into a list — which is a human's decision.
    #
    # Every write to countfile is printf, never print: ORS is \r\n for a CRLF
    # note, and a count that reads back as "1\r" fails the caller's numeric
    # check and makes a real sweep look like an empty one.
    if (!tasks) { printf("0\n") > countfile; exit }

    tasks_next = section_end(tasks)

    # Split the section into what stays and what moves.
    i = tasks + 1
    while (i < tasks_next) {
        if (is_top_done(L[i])) {
            j = i + 1
            while (j < tasks_next && is_child(L[j])) j++

            moved++
            mv[++nm] = L[i]
            for (k = i + 1; k < j; k++) {
                c = L[k]
                # A child left unchecked under a finished parent is checked on
                # the way out, so "## Done" never holds an open box.
                if (c ~ /^[ \t]+[-*+] \[ \]/) sub(/\[ \]/, "[x]", c)
                mv[++nm] = c
            }
            i = j
            continue
        }
        keep[++nk] = L[i]
        i++
    }

    if (!moved) { printf("0\n") > countfile; exit }

    nk = tidy(keep, nk, kept)

    if (done) {
        done_next = section_end(done)
        for (i = done + 1; i < done_next; i++) raw[++nr] = L[i]
        nd = tidy(raw, nr, items)
    }
    for (i = 1; i <= nm; i++) items[++nd] = mv[i]

    for (i = 1; i <= n; i++) {
        if (i == tasks) {
            print L[i]
            print ""
            for (k = 1; k <= nk; k++) print kept[k]
            if (nk) print ""
            if (!done) {
                print "## Done"
                print ""
                for (k = 1; k <= nd; k++) print items[k]
                print ""
            }
            i = tasks_next - 1
            continue
        }
        if (done && i == done) {
            print L[i]
            print ""
            for (k = 1; k <= nd; k++) print items[k]
            print ""
            i = done_next - 1
            continue
        }
        print L[i]
    }

    printf("%d\n", moved) > countfile
}
AWK

NOW="$(date +%s)"
TOTAL=0
NOTES=0
ERRORS=0

for f in "${FILES[@]}"; do
    rel="todo/$(basename "${f}")"

    mtime="$(stat -c %Y "${f}" 2>/dev/null)"
    if [ -z "${mtime}" ] || [ $(( NOW - mtime )) -lt $(( SETTLE_MIN * 60 )) ]; then
        log "${rel}: edited within ${SETTLE_MIN}m, leaving it for the next cycle"
        continue
    fi

    tmp="$(mktemp)"
    count="$(mktemp)"

    if ! awk -v countfile="${count}" "${SWEEP_AWK}" "${f}" > "${tmp}"; then
        echo "[sweep] ${rel}: awk failed, left untouched" >&2
        ERRORS=$(( ERRORS + 1 ))
        rm -f "${tmp}" "${count}"
        continue
    fi

    moved="$(cat "${count}" 2>/dev/null)"
    moved="${moved%$'\r'}"
    case "${moved}" in ''|*[!0-9]*) moved=0 ;; esac

    if [ "${moved}" -gt 0 ]; then
        # Written through the existing file rather than moved over it: the vault
        # is shared with the Samba and File editor add-ons, and mktemp's 0600
        # would take it away from them.
        if cat "${tmp}" > "${f}"; then
            log "${rel}: moved ${moved} task(s) to Done"
            TOTAL=$(( TOTAL + moved ))
            NOTES=$(( NOTES + 1 ))
        else
            echo "[sweep] ${rel}: write failed, left untouched" >&2
            ERRORS=$(( ERRORS + 1 ))
        fi
    fi

    rm -f "${tmp}" "${count}"
done

# A run that moved something is worth committing even if another note failed;
# the failure is on stderr either way. Only a run that moved nothing at all
# reports the failure through its exit status.
if [ "${TOTAL}" -eq 0 ]; then
    [ "${ERRORS}" -gt 0 ] && exit 2
    log "nothing finished since the last sweep"
    exit 1
fi

log "swept ${TOTAL} task(s) across ${NOTES} note(s)"
exit 0

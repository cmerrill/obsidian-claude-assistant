#!/usr/bin/env bash
# Git helpers for the vault. Sourced by triage.sh, never run directly.
#
# Git is backup and history here, not transport — Obsidian Sync moves the files.
# Claude never runs a git command, so a bad run can dirty the tree but can never
# wedge the repo.

git_v() { git -C "${VAULT}" "$@"; }

# Pull remote history. Autostash covers files Obsidian Sync wrote mid-pull.
vault_pull() {
    if ! git_v pull --rebase --autostash --quiet origin "${GIT_BRANCH}"; then
        echo "[git] pull failed; aborting any in-progress rebase" >&2
        git_v rebase --abort 2>/dev/null || true
        return 1
    fi
}

# Commit everything currently on disk. Returns 1 when there was nothing to do.
vault_commit() {
    local message="$1"
    git_v add -A
    if git_v diff --cached --quiet; then
        return 1
    fi
    git_v commit --quiet -m "${message}"
    echo "[git] committed: ${message}"
}

# Push, rebasing onto whatever landed in the meantime. Obsidian mobile and a
# desktop session can both push while a cycle is running.
vault_push() {
    local attempt
    for attempt in 1 2 3; do
        if git_v push --quiet origin "${GIT_BRANCH}"; then
            return 0
        fi
        echo "[git] push rejected (attempt ${attempt}/3), rebasing" >&2
        vault_pull || return 1
    done
    echo "[git] push failed after 3 attempts" >&2
    return 1
}

vault_commit_and_push() {
    if vault_commit "$1"; then
        vault_push
    fi
}

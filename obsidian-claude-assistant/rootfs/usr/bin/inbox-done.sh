#!/usr/bin/env bash
# Remove one captured note from inbox/ after it has been filed elsewhere.
#
#   inbox-done.sh "kiln.md"
#   inbox-done.sh "inbox/kiln.md"      # same thing
#
# This exists so the triage prompt never needs plain `rm`. A permission rule
# like Bash(rm inbox/*) only matches a string prefix, so `rm "inbox/x.md"` with
# quotes, or a crafted `inbox/../../x`, would slip past or fail confusingly.
# Here the constraint is enforced after resolving the path, which is the only
# way to actually mean "inside inbox/".
#
# Refuses anything that is not a regular .md file sitting directly in
# $VAULT/inbox. Never recurses, never globs, never takes more than one file.
set -uo pipefail

VAULT="${VAULT:-$(pwd)}"
INBOX="${VAULT}/inbox"

NAME="${1:-}"
[ -z "${NAME}" ] && { echo "usage: inbox-done.sh <file.md>" >&2; exit 2; }

# Accept either a bare name or an inbox/-prefixed one, nothing else.
NAME="${NAME#inbox/}"
NAME="${NAME#./}"

case "${NAME}" in
    */*|..*|/*|"")
        echo "inbox-done: refusing '${1}' — must name a file directly in inbox/" >&2
        exit 1
        ;;
esac

case "${NAME}" in
    # .gitkeep is what holds inbox/ open in git once the last capture is filed.
    # The .md rule below already covers it; named here so the refusal explains
    # itself rather than looking like an arbitrary extension check.
    .gitkeep)
        echo "inbox-done: refusing '${1}' — .gitkeep keeps inbox/ in git" >&2
        exit 1
        ;;
    *.md) ;;
    *) echo "inbox-done: refusing '${1}' — only .md files" >&2; exit 1 ;;
esac

TARGET="${INBOX}/${NAME}"

if [ ! -f "${TARGET}" ] || [ -L "${TARGET}" ]; then
    echo "inbox-done: '${NAME}' is not a regular file in inbox/" >&2
    exit 1
fi

# Belt and braces: resolve symlinks and confirm the parent really is inbox/.
resolved_dir="$(cd "$(dirname "${TARGET}")" && pwd -P)"
inbox_dir="$(cd "${INBOX}" && pwd -P)"
if [ "${resolved_dir}" != "${inbox_dir}" ]; then
    echo "inbox-done: '${NAME}' resolves outside inbox/, refusing" >&2
    exit 1
fi

rm -- "${TARGET}"
echo "removed inbox/${NAME}"

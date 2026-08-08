#!/usr/bin/env bash
# Obsidian Sync, headless. s6 restarts this if the connection drops.
set -e
# shellcheck source=/dev/null
. /data/env.sh

# Log in on every start rather than tracking a marker file. `ob login` is
# idempotent, the credentials are already in the add-on options, and this way
# the service does not depend on where `ob` chooses to cache them.
#
# MFA must be disabled on the account: `ob login --mfa` takes a one-time code,
# which a daemon has no way to supply.
echo "[sync] logging in as ${OBSIDIAN_EMAIL}"
if ! ob login --email "${OBSIDIAN_EMAIL}" --password "${OBSIDIAN_PASSWORD}"; then
    echo "[sync] login failed — check credentials, and that 2FA is off" >&2
    exit 1
fi

# The link lives with the vault, so it survives restarts. Re-linking an already
# linked path is what sync-status is checked for.
if ! ob sync-status --path "${VAULT}" --json >/dev/null 2>&1; then
    echo "[sync] linking ${VAULT} to remote vault '${OBSIDIAN_VAULT_NAME}'"
    ob sync-setup --vault "${OBSIDIAN_VAULT_NAME}" --path "${VAULT}"
else
    echo "[sync] ${VAULT} already linked"
fi

echo "[sync] starting continuous sync"
exec ob sync --path "${VAULT}" --continuous

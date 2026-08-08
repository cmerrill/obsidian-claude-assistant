# Obsidian Claude Assistant

A Home Assistant add-on repository containing one add-on:
**[Obsidian Claude Assistant](obsidian-claude-assistant/)**.

Share a URL or a scrap into your Obsidian vault's `inbox/` from your phone. The
add-on syncs the vault headlessly, works out what the note actually is, files it
into the right folder in the right format, and commits it to git. When it isn't
sure, it files its best guess and asks you by push notification — and you answer
from the notification itself, as many rounds as it takes.

## Install

Settings → Add-ons → Add-on Store → ⋮ → Repositories, and add:

```
https://github.com/cmerrill/obsidian-claude-assistant
```

Then install **Obsidian Claude Assistant** and follow
[its README](obsidian-claude-assistant/README.md).

## Requirements

- An active [Obsidian Sync](https://obsidian.md/sync) subscription, with 2FA off
- A Claude subscription, for `claude setup-token`
- A git remote for the vault, and a deploy key with write access
- The Home Assistant Companion app, for notifications and replies

## Note on the vault

The add-on's behaviour lives in your *vault*, not in this image:
`.claude/commands/triage-inbox.md` and `.claude/commands/resolve-review.md`,
alongside the `CLAUDE.md` that describes your note types. Change how triage
works by editing those and syncing — no rebuild.

That also means this add-on assumes a vault with a `CLAUDE.md` defining your
note types, and templates to match. It is built around one person's vault
conventions; treat it as a starting point rather than a turnkey product.

## Licence

MIT

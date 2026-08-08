# Obsidian Claude Assistant

Keeps an Obsidian vault synced headlessly, then files anything you drop in
`inbox/` into the right note type and folder using Claude Code. Commits and
pushes to GitHub as a backup. Asks by push notification when it is unsure, and
takes your answer straight from the notification.

## How it works

```
Android (Obsidian mobile)
      |  Obsidian Sync
      v
[1] ob sync --continuous  <-->  /share/notes  <-->  GitHub (backup + history)
                                     ^                    ^
[2] triage-loop ---------------------+--------------------+
      every N minutes, or the instant a reply arrives:
        wait for the vault to stop moving
        git pull
        git commit + push          <- the raw capture enters history HERE
        apply any queued replies
        skip inbox notes touched in the last 2 minutes
        nothing ready? stop, no tokens spent
        claude -p "/triage-inbox <the settled notes>"
        git commit + push
        notify about flagged and stuck notes
                                     |
      HA Companion push  <-----------+
            |  tap Answer, type a few words
            v
[3] reply-listener  --websocket-->  supervisor/core/websocket
```

Three independent s6 services. One can crash and restart without disturbing the
others.

**The shell owns git and Obsidian Sync; Claude only writes note content.** Claude
never runs a git command, so a bad run can dirty the tree but can never wedge the
repository.

**The prompts live in the vault, not in this image.** `.claude/commands/triage-inbox.md`
and `.claude/commands/resolve-review.md` sit in the notes repo next to the
`CLAUDE.md` they depend on. Change how triage behaves by editing those files and
syncing — no rebuild.

**A note has to sit still before it is filed.** Obsidian Sync pushes a capture
while you are still typing it. Triaging that would file half a thought, then
delete the file before the rest arrives. So a note is skipped until its mtime is
at least `inbox_settle_minutes` old, and the eligible names are passed to
`/triage-inbox`. Your `triage-inbox.md` must file the notes named in the
arguments rather than everything in `inbox/`, or the guard does nothing.

## What you have to provide

| Option | Where it comes from |
|---|---|
| `obsidian_email` / `obsidian_password` | Your Obsidian account. **2FA must be off** — see below |
| `obsidian_vault_name` | Exact name of your remote Sync vault — `ob sync-list-remote` prints it |
| `claude_oauth_token` | `claude setup-token` on any machine |
| `git_ssh_key` | Private half of a new ed25519 deploy key, base64-encoded |
| `git_repo_url` | e.g. `git@github.com:you/notes.git` |
| `notify_service` | Developer Tools → Actions → the part of `notify.mobile_app_…` after `notify.` |

The rest have working defaults.

### Obsidian credentials

Requires an active Obsidian Sync subscription and Node 22 or later.

`ob login` takes `--email` and `--password` — there is no long-lived token to
issue, so the add-on stores your account password and logs in on every start.
Two consequences worth knowing:

- **2FA must be disabled on the account.** `ob login --mfa` expects a one-time
  code, which a background service cannot supply.
- The password appears in the container's process list during login. That is
  visible to anything already running inside this container, and nothing else.

To confirm your vault's exact name before installing:

```bash
npm install -g obsidian-headless
ob login
ob sync-list-remote
```

Put that name in `obsidian_vault_name`.

### Claude token

```bash
claude setup-token
```

Uses your Claude subscription rather than per-token API billing.

### Deploy key

```bash
ssh-keygen -t ed25519 -C "obsidian-claude-assistant" -f ./obsidian-claude-key -N ""
```

On Windows PowerShell, quote the empty passphrase as `'""'`. A bare `""` is
stripped before `ssh-keygen` sees it, and you get `option requires an argument
-- N`:

```powershell
ssh-keygen -t ed25519 -C "obsidian-claude-assistant" -f ./obsidian-claude-key -N '""'
```

The key must have no passphrase — nothing can type one at boot.

Add `obsidian-claude-key.pub` to the notes repo under Settings → Deploy keys with
**Allow write access**. A deploy key is scoped to one repository; a personal
access token is not.

The private key goes in `git_ssh_key`. That field is a single line, because the
add-on options form has no multiline input. So encode the key first:

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("$PWD\obsidian-claude-key")) | Set-Clipboard
```

```bash
base64 -w0 ./obsidian-claude-key | tr -d '\n'
```

Paste the result into `git_ssh_key`. The add-on decodes it at start.

A raw private key is also accepted, for anyone who prefers the Configuration
tab's ⋮ → **Edit in YAML** view:

```yaml
git_ssh_key: |
  -----BEGIN OPENSSH PRIVATE KEY-----
  b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAA...
  -----END OPENSSH PRIVATE KEY-----
```

Indent every key line the same amount. Do not re-save from the form view after
that — the single-line field flattens the newlines.

## Install

1. Settings → Add-ons → Add-on Store → ⋮ → Repositories → add
   `https://github.com/cmerrill/obsidian-claude-assistant`.
2. Install **Obsidian Claude Assistant**.
3. Fill in the options above.
4. Start it, and watch the log.

First start clones the repo into `/share/notes`, then links it to your remote
Sync vault. Do this when both sides already agree — a first-run reconcile between
two divergent copies is not something you want to debug.

`/share/notes` is reachable from the Samba, SSH, and File editor add-ons, so you
can inspect the repo or unwedge a git state without touching this add-on.

## Options

| Option | Default | Notes |
|---|---|---|
| `interval_minutes` | `10` | Poll interval. A reply wakes the loop immediately regardless. |
| `inbox_settle_minutes` | `2` | A note is skipped until it has been untouched this long. Guards against filing a capture mid-edit. `0` disables the wait. |
| `model` | `opus` | `sonnet` is cheaper and usually fine for well-formed captures. |
| `notify_on` | `questions` | `always`, `questions`, or `errors`. |
| `enable_replies` | `true` | Off means notifications carry no action buttons. |
| `max_notifications_per_cycle` | `3` | Stops a large batch from spamming your phone. |
| `max_review_rounds` | `5` | After this many rounds on one note, it gives up and says so. |
| `vault_path` | `/share/notes` | |

## The reply loop

When Claude is unsure it still files the note, then adds `needs-review: true`,
`review-round: 1`, and an `## Open questions` section. The note itself is the
transcript — no conversation state lives in the container, so it survives
restarts and is readable in Obsidian.

You get one notification per flagged note, with three actions:

- **Answer** — free text. Goes back to Claude, which applies it and either
  resolves the note or asks one narrower follow-up.
- **Looks good** — clears the flag. Handled in shell; no Claude call, no tokens.
- **Stop asking** — sets `review-stopped: true` and silences that note.

The notification `tag` stays constant across rounds, so Android replaces it
rather than stacking. One live notification per note, updating as the
conversation moves.

Add a `Needs Review.base` view to the vault to see everything flagged at once.

## Cost

Claude runs only when there is an inbox file or a queued reply. An empty tick
costs nothing. **Looks good** costs nothing.

## Troubleshooting

**Nothing is syncing** — check the log for `logging in as …`. A login failure
almost always means 2FA is enabled on the account. To force a re-link, run
`ob sync-unlink --path /share/notes` and restart the add-on.

**Push rejected repeatedly** — the deploy key probably lacks write access.

**No notifications** — confirm `notify_service` matches a real
`notify.mobile_app_*` action in Developer Tools.

**Replies never arrive** — check the log for `authenticated, subscribing`. If the
supervisor websocket is refused, fall back to an HA automation on
`mobile_app_notification_action` that appends the same JSON line to
`/data/replies.jsonl` and touches `/data/wake`:

```json
{"note":"restaurants/bar-tartine.md","action":"REPLY","reply_text":"561 Valencia"}
```

**A note keeps failing** — after 3 attempts it moves to `inbox/stuck/` and you
get one notification. Fix it by hand and move it back to `inbox/`.

## State

Everything mutable lives in `/data`, which persists across restarts and is
included in add-on backups:

| File | Purpose |
|---|---|
| `home/` | `$HOME` for the service user: the deploy key, `.gitconfig`, and whatever `ob` caches after login. Deliberately here and not in the image, which a restart or update would wipe |
| `env.sh` | Resolved options and secrets |
| `replies.jsonl` | Queued notification actions |
| `attempts.json` | Per-file failure counts for the stuck check |
| `notified.json` | Last round notified per note, so nothing pings twice |
| `threads.json` | Claude session id per note, for conversation resume |
| `geocode-cache.json` | Address → coordinates, so a repeated address costs no request |
| `last-run.json` | Full JSON output of the most recent Claude run |

## What Claude is allowed to do

By default the add-on does **not** bypass permissions. Claude runs with
`--permission-mode acceptEdits` plus a named allowlist:

```
Read, Glob, Grep, WebFetch, WebSearch,
Bash(geocode.sh *), Bash(inbox-done.sh *), Bash(ls *)
```

`AskUserQuestion` and `Skill` are explicitly removed from the pool — nobody is
watching a background run, and in testing the model would otherwise reach for
`AskUserQuestion`, get refused, and abandon the rest of the batch.

There is deliberately **no `rm` rule**. Deleting a captured note goes through
`inbox-done.sh`, which resolves the path and refuses anything that is not a
regular `.md` file sitting directly in `inbox/`. A permission rule such as
`Bash(rm inbox/*)` only matches a string prefix, so `rm "inbox/x.md"` with
quotes fails while `rm inbox/../../x` passes — the script checks where the file
actually is instead.

Anything refused is logged as `tools refused this run: …`. That line is the
signal to widen the allowlist, not to switch modes.

Set `permission_mode: bypass` to fall back to `--dangerously-skip-permissions`
if something legitimate is blocked and you need it working now.

## Geocoding

`coordinates` drives the map, and a wrong pin is worse than a missing one — it
looks correct. So the container ships `/usr/bin/geocode.sh`, which the triage
prompt calls instead of recalling coordinates from memory:

```bash
geocode.sh "2101 Sutter St, San Francisco, CA"
# 37.7858, -122.435
```

It queries Nominatim with a real User-Agent, holds to the one-request-per-second
policy, caches every answer, and exits non-zero rather than guessing. The prompt
treats a non-zero exit as "leave `coordinates` empty and flag the note".

Running the prompt outside the add-on — on a desktop, say — the script is
absent, and the prompt falls back to a `WebFetch` against the same endpoint.

# Obsidian Claude Assistant

Keeps an Obsidian vault synced headlessly, then files anything you drop in
`inbox/` into the right note type and folder using Claude Code. Commits and
pushes to GitHub as a backup. Asks by push notification when it is unsure, and
takes your answer straight from the notification — or from its web page in the
Home Assistant sidebar, where long answers, pasted pages, and file uploads fit.
Sweeps finished tasks out of `todo/` lists on the same schedule.

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
        sweep finished tasks in todo/ into their "## Done" section
        git commit + push
        notify about flagged and stuck notes
                                     |
      HA Companion push  <-----------+
            |  tap Answer, type a few words
            v
[3] reply-listener  --websocket-->  supervisor/core/websocket

      HA sidebar / notification tap
            |  ingress
            v
[4] web-ui  ->  same replies queue as [3], plus uploads into attachments/
                and captures into inbox/
```

Four independent s6 services. One can crash and restart without disturbing the
others.

**The shell owns git and Obsidian Sync; Claude only writes note content.** Claude
never runs a git command, so a bad run can dirty the tree but can never wedge the
repository.

**The prompts live in the vault, not in this image.** `.claude/commands/triage-inbox.md`
and `.claude/commands/resolve-review.md` sit in the notes repo next to the
`CLAUDE.md` they depend on. Change how triage behaves by editing those files and
syncing — no rebuild.

**The todo sweep is the exception, and is shell.** Moving a ticked checkbox
from `## Tasks` to `## Done` is mechanical, so it runs as
[todo-sweep.sh](rootfs/usr/bin/todo-sweep.sh) rather than as a prompt: no
tokens on a cycle where nothing was ticked, and the task text is moved
byte-for-byte instead of being retyped by a model. Changing its behaviour does
need a rebuild.

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

The vault must already contain an `inbox/` folder — the add-on does not create
one. Git does not track empty directories, so commit an `inbox/.gitkeep` to the
notes repo to hold the folder open once the last capture has been filed;
otherwise `inbox/` disappears from the repo and from every other clone. If the
folder is missing at start, the log says so and nothing is ever triaged.

Nothing in the add-on touches `.gitkeep`. Every scan of `inbox/` globs `*.md`,
dotfiles are skipped explicitly, and `inbox-done.sh` refuses to delete it.
Obsidian does not sync dotfiles either, so it stays a git-side artefact and
never appears on your phone.

First start clones the repo into `/share/notes`, then links it to your remote
Sync vault. Do this when both sides already agree — a first-run reconcile between
two divergent copies is not something you want to debug.

`/share/notes` is reachable from the Samba, SSH, and File editor add-ons, so you
can inspect the repo or unwedge a git state without touching this add-on.

## Options

| Option | Default | Notes |
|---|---|---|
| `interval_minutes` | `10` | Poll interval. A reply wakes the loop immediately regardless. |
| `inbox_settle_minutes` | `2` | A note is skipped until it has been untouched this long. Guards against filing a capture mid-edit, and against sweeping a `todo/` note someone is editing. `0` disables the wait. |
| `model` | `sonnet` | Cheap, and usually fine for well-formed captures. Set `opus` if triage keeps guessing the type wrong. |
| `notify_on` | `questions` | `errors` = only failures. `questions` = failures + flagged notes. `always` = those plus a notice when work completes: "Filed N note(s)" after a triage, "Applied your reply" after an answer. Suppressed for a note that comes out of the run still needing review — its question notification covers that instead, so you don't get both. |
| `enable_replies` | `true` | Off means notifications carry no action buttons. |
| `max_notifications_per_cycle` | `3` | Stops a large batch from spamming your phone. |
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

**Tapping the notification body opens the add-on's web page**, where the same
question sits with a full reply box. On Android the notification is also
`sticky`, so the tap doesn't dismiss it — answering (with **Answer**, **Looks
good**, or from the page) clears it for you.

**A question is never re-sent, and never expires.** You get exactly one
notification per round. A notification lost to a swipe, a phone that was off,
or an app update costs nothing: the question stays on the web page until you
answer it there. (Earlier versions re-sent "still waiting" reminders and gave
up after a round cap — both existed only because a lost notification used to
mean a lost question.)

Add a `Needs Review.base` view to the vault to see everything flagged at once.

## The web page

The add-on serves a small page through Home Assistant ingress — it appears as
**Claude Assistant** in the sidebar and in the Companion app, works wherever
your HA does (including remote access), and needs no open ports or extra
login. It is the durable record of everything still waiting on you:

- **Every open question**, with its full `## Open questions` text — no
  notification-length truncation — a big reply box for pasted pages of text,
  file upload, and the same **Looks good** / **Stop asking** buttons.
- **A drop box**: paste text and/or upload files with an optional title, and
  it lands in `inbox/` as a fresh capture for the next triage cycle.

Uploads go to `attachments/` in the vault, so git backs them up and Obsidian
Sync carries them to your other devices — for binaries that requires the
vault's **Sync all other types** setting; git backs them up regardless. Claude
reads them with its `Read` tool (PDFs included), so "the page you couldn't
fetch" can be answered with a printout of it.

Each upload has a **delete after processing** checkbox. Ticked files are
removed by the add-on — not by Claude — once their note is dealt with: for a
reply, when the question is resolved, confirmed, or stopped; for a drop-box
capture, when it has been filed. A note still mid-conversation keeps its
files. Deleted files remain in git history (they were committed on arrival),
so ticking the box is about clutter, not risk. An upload abandoned before its
submit button was pressed just sits in `attachments/` — harmless, and yours to
remove.

A reply longer than ~4 KB is saved into `attachments/` as a file and handed to
Claude as a path instead of inline text; this is invisible in use.

## The todo sweep

Ticking a box in Obsidian leaves the item where it was, so a list you actually
use fills up with things that are already done. Every cycle, after the inbox
pass, [todo-sweep.sh](rootfs/usr/bin/todo-sweep.sh) walks `todo/*.md` and moves
each finished **top-level** task into that note's `## Done` section.

```markdown
## Tasks                        ## Tasks

- [ ] Bike rain jacket          - [ ] Bike rain jacket
- [x] Running shoes      ->     - [ ] Dress shoes
- [ ] Dress shoes
                                ## Done
## Done
                                - [x] Travel toothbrush
- [x] Travel toothbrush         - [x] Running shoes
```

What it will and will not do:

- **Only a top-level `- [x]` moves.** A checked subtask under an unchecked
  parent stays nested exactly where it is — the parent is what "done" means.
- **A moved task takes its children with it**, and any child still unchecked is
  checked on the way out. Ticking the parent is the statement that the whole
  thing is finished, so `## Done` never ends up holding an open box.
- **`## Done` is created only when there is something to put in it**, directly
  after `## Tasks`, so `## Notes` stays last.
- **`status` is never touched.** A shopping list whose `## Tasks` is empty is
  still `status: open` — deciding a todo note is finished stays your call, and
  a recurring list would otherwise close itself every time you cleared it.
- **A note with no `## Tasks` section is left alone.** That is a single-task
  todo, and giving it sections would turn it into a list.
- **Nothing else in the file changes.** Frontmatter, prose, ordering, and CRLF
  line endings all survive; the task text is moved, never rewritten.

A todo note is skipped until it has been untouched for `inbox_settle_minutes`,
same as an inbox capture — rewriting a file under a live Obsidian editor invites
a sync conflict over a cosmetic change. So a box ticked just now is swept on the
following cycle, not this one.

The sweep is confined to `todo/`. `projects/` notes have the same `## Tasks`
structure but no `## Done` convention, and are left alone.

## Cost

Claude runs only when there is an inbox file or a queued reply. An empty tick
costs nothing. **Looks good** costs nothing. The todo sweep is shell, so it
costs nothing either — on any cycle, whether or not it moves something.

## Troubleshooting

**Nothing is ever triaged** — check the log for `does not exist` at start. The
add-on does not create `inbox/`; if git dropped the folder when the last capture
was filed, add it back with an `inbox/.gitkeep` committed to the notes repo.

**Nothing is syncing** — check the log for `logging in as …`. A login failure
almost always means 2FA is enabled on the account. To force a re-link, run
`ob sync-unlink --path /share/notes` and restart the add-on.

**Push rejected repeatedly** — the deploy key probably lacks write access.

**No notifications** — confirm `notify_service` matches a real
`notify.mobile_app_*` action in Developer Tools.

**The web page shows 403** — only Home Assistant's ingress proxy may talk to
it. Open it through the sidebar or the Companion app, not by dialing the
container's port directly.

**Tapping a question notification does nothing** — the add-on could not
resolve its own slug at start (the init log will show a warning). Restart the
add-on; until then the page is still reachable from the sidebar.

**Replies never arrive** — check the log for `authenticated, subscribing`. If the
supervisor websocket is refused, fall back to an HA automation on
`mobile_app_notification_action` that appends the same JSON line to
`/data/replies.jsonl` and touches `/data/wake`:

```json
{"note":"restaurants/bar-tartine.md","action":"REPLY","reply_text":"561 Valencia"}
```

**Answer opens a text field on Android but not on iOS** — the free-text
**Answer** action carries `behavior: textInput` for iOS as well as Android's
`REPLY` magic name, so this should not happen on a current install. If it
still does, the app is likely stale enough to ignore `behavior`; update the
Companion app.

**A note keeps failing** — after 3 attempts it moves to `inbox/stuck/` and you
get one notification. Fix it by hand and move it back to `inbox/`.

**A ticked box did not move to `## Done`** — the log says which. A note edited
within `inbox_settle_minutes` is left for the next cycle, and only a top-level
task moves: a checked subtask stays under its parent until the parent is ticked
too.

## State

Everything mutable lives in `/data`, which persists across restarts and is
included in add-on backups:

| File | Purpose |
|---|---|
| `home/` | `$HOME` for the service user: the deploy key, `.gitconfig`, and whatever `ob` caches after login. Deliberately here and not in the image, which a restart or update would wipe |
| `env.sh` | Resolved options and secrets |
| `replies.jsonl` | Queued answers, from notification actions and the web page alike |
| `attempts.json` | Per-file failure counts for the stuck check |
| `notified.json` | Last round notified per note, so nothing pings twice |
| `ephemeral.json` | Uploads marked "delete after processing", keyed by the note that owns them |
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

# Changelog

All notable changes to this add-on are documented here. Format loosely
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions
match `config.yaml`.

## 0.7.2 — 2026-08-23

### Fixed
- Tapping a question notification (or the shortcut notification) always
  landed on a 404, even from the sidebar's own device and with the
  Companion app already open. The tap target was built as
  `/hassio/ingress/<slug>` — the Supervisor's internal proxy path, not a
  frontend route. The frontend actually registers an add-on's ingress
  panel at `/<slug>` directly (confirmed against `home-assistant/core`'s
  `addon_panel.py`, which passes the slug straight through as
  `frontend_url_path`). This was a regression from 0.6.0, when the
  ingress web page and its deep link were introduced.

## 0.7.1 — 2026-08-23

### Fixed
- Ephemeral-attachment cleanup could delete an inbox upload marked
  "delete after processing" before triage ever read it. A freshly
  dropped capture has no `needs-review` key until `triage-inbox`
  processes it, so the cleanup step's "no `needs-review: true` means
  done" check could fire on the very next cycle, ahead of the mtime
  settle wait. An inbox owner is now only "done" once it has left its
  original inbox path (filed, or parked in `inbox/stuck/`) or was
  explicitly stopped.

## 0.7.0 — 2026-08-15

### Changed
- Question notifications are no longer sticky. The tap now lands on the
  ingress page, which lists the same question with a full reply box, so
  Android's default (dismiss on tap) is what's wanted. The notification
  still stays sticky with a no-op tap when the add-on couldn't resolve
  its own slug, since then there's no page to land on.

### Added
- `persistent_shortcut` option (default off): an ongoing, silent Android
  notification whose only job is to open the ingress page — its own
  channel at `min` importance, `persistent` + `sticky` so neither a swipe
  nor a tap removes it. Re-posted when the web page is opened (the one
  moment its absence is provable), not on a timer. Turning the option
  off clears it on the next start.

### Docs
- Documented why a question tap can fail away from home: the tap path is
  already a network-agnostic relative path, so the "use external URL"
  prompt is the Companion app failing to detect it has left the house —
  a location-permission / SSID-list issue on the phone, not the add-on.

## 0.6.3 — 2026-08-11

### Fixed
- Confirming a note ("Looks good") cleared its `needs-review` frontmatter
  but left the now-irrelevant `## Open questions` section sitting in the
  note body forever. It's now stripped in the same step.
- `notify_on: always` could double-notify: a "Filed N note(s)" or
  "Applied your reply" notice could fire alongside a fresh question
  notification for the same note in the same cycle. The reply path now
  skips its notice when the note is still flagged afterward; the
  inbox-filing path excludes notes the batch itself newly flagged from
  its count, and only de-dupes by name for an unambiguous single-note
  batch (a multi-note batch can rename captures on the way in, so there's
  no reliable mapping back to an original filename).

## 0.6.0 — 2026-08-11

### Added
- An ingress web page (sidebar panel, no ports, HA handles auth) listing
  every note awaiting review with its full `## Open questions` text, an
  unbounded reply box, file uploads, and the same **Looks good** /
  **Stop asking** actions as the notification. A drop box on the same
  page sends pasted text and/or files into `inbox/` as a fresh capture.
- File uploads land in `attachments/`, where git and Obsidian Sync
  already carry them, and Claude reads them with its allowlisted `Read`
  tool. A **delete after processing** checkbox marks an upload as
  ephemeral; a deterministic cleanup step removes it once its owning
  note is resolved, confirmed, stopped, or filed — never mid-conversation,
  and never by the model.
- Question notifications deep-link to the page via `clickAction`/`url`.
  *(The relative path used here was wrong until 0.7.2 — see above.)*

### Removed
- The re-notification machinery (`renotify_after_minutes`,
  `max_review_rounds`) — with the web page as the durable record of open
  questions, a lost notification costs nothing, so there's no more
  "still waiting" re-send or give-up cap.

## 0.5.0 — 2026-08-09

### Added
- A todo sweep: every cycle, finished top-level tasks in `todo/*.md` move
  into that note's `## Done` section (creating it above `## Notes` if
  needed), taking their still-checked children with them and
  auto-checking any unchecked child under a finished parent. A note with
  nothing left open is *not* auto-closed — `status` stays a human call,
  since some notes (a shopping list) are meant to stay open forever.

### Fixed
- `inbox/.gitkeep` is left alone instead of being implicitly relied on by
  accident; dotfiles in `inbox/` are now explicitly skipped rather than
  merely missed by an unglobbed `*.md` pattern. The add-on no longer
  creates `inbox/` itself — a missing folder now just logs a warning.
- The frontmatter/JSON in-place rewriters (`fm_set`, `fm_drop`, `json_set`,
  `json_del`) built their replacement in a `mktemp` file (mode 0600) and
  `mv`'d it over the target, silently dropping every touched vault note
  from `644` to `600` — invisible to Samba, SSH, and the File Editor
  add-on. They now write through the existing file, preserving its mode,
  owner, and inode.

## 0.4.5 — 2026-08-09

### Fixed
- Notification questions were capped at 1000 bytes, well past what
  Android's shade actually renders (~430 bytes / 10 lines of expanded
  `BigText`, cut with no indication anything was lost). Capped at 430
  bytes to match, so the ellipsis already appended marks a truncation
  the reader could otherwise not see.

## 0.4.4 — 2026-08-09

### Fixed
- `last_question()` only matched a question's first physical markdown
  line, so a question hard-wrapped across several lines was cut mid-
  sentence at the wrap column — with no ellipsis, since by then the
  extracted string genuinely was that short. Rewritten in `awk` to fold
  in indented continuation lines, ending at a blank line, a new list
  item, a heading, or a rule. An over-cap question is now trimmed back to
  a word boundary rather than a hard byte index, so a multi-byte
  character (an em dash) can't be split into invalid UTF-8.

## 0.4.3 — 2026-08-09

### Changed
- Logs how many characters of question text each notification actually
  carries, to tell apart two different failure modes: a count well below
  the note's real question means the add-on's own extraction lost text;
  a count that matches while the phone shows less means Android's shade
  is capping the expanded height.

## 0.4.2 — 2026-08-09

### Fixed
- A reply batch claimed by the triage loop (`replies.jsonl` renamed to
  `replies.processing.jsonl`) was stranded and silently lost if the
  add-on died between the claim and its cleanup — e.g. a container reset
  mid-drain — even though the phone had already delivered those answers.
  Any leftover `replies.processing.jsonl` is now folded back onto the
  live queue at the start of the next drain, appended rather than
  overwritten so a reply the listener is writing at that instant can't
  be clobbered.

## 0.4.1 — 2026-08-09

### Fixed
- The notification body (the last transcript question) was cut at 180
  characters, short enough to slice a normal question mid-sentence.
  Raised to 1000 characters, with an ellipsis appended when a question is
  actually truncated.

## 0.4.0 — 2026-08-08

### Fixed
- Tapping a question notification opened the app and dismissed the
  notification with no way to get the question back. Question
  notifications are now sticky with `clickAction: noAction` on Android;
  only **Answer** / **Looks good** / **Stop asking** clear one. The
  **Answer** action gains `behavior: textInput` for iOS, which previously
  fired `REPLY` with no reply text at all.

### Added
- `renotify_after_minutes` option to re-send a notification for anything
  still unanswered. *(Removed again in 0.6.0 once the web page made it
  unnecessary.)*

## 0.3.0 — 2026-08-08

### Fixed
- An inbox capture could be triaged while Obsidian Sync was still
  writing it, filing a half-finished thought and deleting the file
  before the rest arrived. A note is now skipped until its mtime is at
  least `inbox_settle_minutes` old (default 2); the stuck-file counter
  follows the same settled list instead of re-scanning `inbox/` on its
  own. The startup quiesce wait was also lengthened.

## 0.2.0 — 2026-08-08

### Added
- `git_ssh_key` accepts a base64-encoded private key, so it fits the
  add-on options form's single-line fields instead of requiring the
  Configuration tab's raw YAML editor. A raw (non-base64) key still
  works.

## 0.1.0 — 2026-08-08

### Added
- Initial release. A Home Assistant add-on that syncs an Obsidian vault
  headlessly and files anything dropped in `inbox/` into the right note
  type and folder using Claude Code, running three s6 services in one
  container: `obsidian-sync` (continuous `ob sync`), `triage-loop`
  (poll, or wake instantly on a reply), and `reply-listener` (HA
  websocket → notification replies → the loop). Claude runs under an
  allowlist rather than bypassed permissions; deletion goes through
  `inbox-done.sh`, which resolves the real path and refuses anything
  that isn't a regular `.md` file directly in `inbox/`.

# Next steps

## Superseded: tap-to-reply-box (input_text helper)

This file used to hold a full design for making a notification tap open an
`input_text.obsidian_claude_reply` more-info dialog, published via a
`sensor.obsidian_claude_pending` state and routed back through a custom event.

0.6.0 made it moot. Tapping a question now opens the add-on's **ingress web
page** ([web-ui.js](rootfs/usr/bin/web-ui.js)), which solves everything the
input_text route couldn't, including that design's own recorded caveats:

- *One question at a time* — the page lists every flagged note, each with its
  own reply box.
- *255-character cap* — the textarea is unbounded; replies past ~4 KB are
  spilled to a file automatically.
- *State lost on HA restart* — the page renders from the vault's frontmatter,
  which is the durable record; there is no published state to lose.
- *Helper replaying stale answers* — nothing is stored in an entity at all.

It also does what input_text never could: file uploads (PDF printouts of
pages Claude couldn't fetch) and a drop box for new captures. No helpers, no
automations, no manual Home Assistant setup.

## Genuinely next

- **Answered history.** The page shows only what is waiting. A short "recently
  resolved" list (last few notes to lose their `needs-review` flag, from git
  log) would confirm an answer landed without opening Obsidian.
- **Camera capture in the drop box.** `<input type=file capture>` on the
  page would let a phone photograph a paper recipe straight into `inbox/`.
- **Orphaned upload sweep.** A file uploaded but never attached to a submit
  sits in `attachments/` forever. A cleanup for uploads older than a day that
  no note references would keep the folder honest.
- **Per-question deep link.** The notification could carry
  `#note=<path>` on the ingress URL and the page could scroll to that card.
  Needs care: the ingress path prefix is invisible to the add-on, so the
  fragment has to survive HA's redirect.

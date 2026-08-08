# Next step: tap-to-reply-box

Not implemented. This is a recipe for whoever picks it up next.

## Where things stand

As of 0.4.0, tapping the body of a question notification does nothing —
`clickAction: "noAction"` — and an unanswered question is re-sent after
`renotify_after_minutes`. That fixed the "tap loses the question" bug. It did
not add a way to answer by tapping; you still need to press **Answer** and
type into the Companion app's own reply field.

This note is about that: making the tap itself open a text box.

## Goal

Tap the notification body → a text box opens → type the answer → it reaches
Claude the same way **Answer** already does.

## Mechanism

`clickAction: "entityId:input_text.obsidian_claude_reply"` makes Home
Assistant open that entity's more-info dialog instead of the app's default
screen. For an `input_text` helper, that dialog **is** an editable field — no
dashboard needs building, no Lovelace view to design.

## Add-on side

1. New option `notification_tap`, one of `noAction` (today's default),
   `entity` (this feature). Kept switchable — the entity has to exist in Home
   Assistant before it's safe to point `clickAction` at it.

2. Before sending the `ask` notification, publish the pending question so the
   dialog and the automation below have something to read:

   ```bash
   curl -sS -X POST \
       -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
       -H "Content-Type: application/json" \
       -d "$(jq -n --arg note "${note}" --arg q "${question}" --arg r "${round}" \
             '{state: ($note|ltrimstr("")|split("/")|last|rtrimstr(".md")),
               attributes: {note: $note, question: $q, round: ($r|tonumber)}}')" \
       "http://supervisor/core/api/states/sensor.obsidian_claude_pending"
   ```

   Same proxy and `SUPERVISOR_TOKEN` `notify.sh` already uses.
   `homeassistant_api: true` is already set in `config.yaml`, so no new
   permission is needed.

3. When `notification_tap: entity`, set
   `clickAction: "entityId:input_text.obsidian_claude_reply"` in the `ask`
   payload built by [notify.sh](rootfs/usr/bin/notify.sh).

## Return path

`reply-listener.js` currently subscribes to one event
([reply-listener.js:100-104](rootfs/usr/bin/reply-listener.js#L100-L104)).
Add a second `subscribe_events` call for a custom event, e.g.
`obsidian_claude_reply`, carrying `{ note, reply_text }`. Route it through the
same `record()` used today:

```js
function handleTapReply(data) {
  const note = data?.note;
  if (typeof note !== 'string' || !isNotePath(note)) return;
  record({ note, action: 'REPLY', reply_text: data.reply_text ?? null,
            ts: new Date().toISOString() });
}
```

`isNotePath` ([reply-listener.js:49-56](rootfs/usr/bin/reply-listener.js#L49-L56))
is reused as-is — it is the vault-escape guard, not something specific to the
existing event. Everything downstream of `record()` — the queue file, the wake
touch, `triage.sh`'s drain loop — needs no change at all.

## Home Assistant side

One helper, one automation, both set up by hand in Home Assistant (not shipped
by the add-on — it has no way to create entities in core):

```yaml
# Settings -> Devices & services -> Helpers -> + -> Text
# input_text.obsidian_claude_reply, max length 255
```

```yaml
automation:
  - alias: "Obsidian Claude: send typed reply"
    trigger:
      - platform: state
        entity_id: input_text.obsidian_claude_reply
    condition:
      - condition: template
        value_template: >-
          {{ trigger.to_state.state not in ('', trigger.from_state.state) }}
    action:
      - event: obsidian_claude_reply
        event_data:
          note: "{{ state_attr('sensor.obsidian_claude_pending', 'note') }}"
          reply_text: "{{ trigger.to_state.state }}"
      - service: input_text.set_value
        target:
          entity_id: input_text.obsidian_claude_reply
        data:
          value: ""
```

The trailing `set_value` clears the box, which is also what makes the
`from_state != to_state` condition mean anything — otherwise typing the same
answer twice in a row would not re-fire.

## Caveats worth recording before building this

- **One question at a time.** `sensor.obsidian_claude_pending` holds a single
  note. If two notes are flagged together, the dialog would answer whichever
  one is currently published — this needs either serializing notifications
  (only publish/tap-enable the oldest) or moving the state to a per-note
  entity, which doesn't fit `input_text`'s fixed-entity model.
- **255-character cap.** `input_text` cannot hold more; long answers still
  need the Companion app's own reply field.
- **State set through the REST API does not survive a Home Assistant
  restart.** If the pending sensor is empty, the dialog opens with nothing to
  tell the user which note it's answering — the notification title still
  says, but the dialog itself will look blank.
- **The helper remembers its last value.** The clear-after-send step above is
  what stops a Home Assistant restart replaying a stale answer.

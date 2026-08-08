#!/usr/bin/env node
// Listens for notification actions from the HA Companion app and hands them to
// the triage loop.
//
// Companion app -> mobile_app_notification_action event -> replies.jsonl
//                                                       -> touch /data/wake
//
// Touching the wake file is what makes a reply feel instant: the triage loop is
// blocked on inotifywait against it, so it starts within a second instead of
// waiting out the poll interval.
//
// Node 22 ships a global WebSocket, so this has no dependencies.

const fs = require('fs');

const SUPERVISOR_TOKEN = process.env.SUPERVISOR_TOKEN;
const WS_URL = 'ws://supervisor/core/websocket';
// Overridable so the parsing can be exercised outside the container.
const REPLIES = process.env.REPLIES_PATH || '/data/replies.jsonl';
const WAKE = process.env.WAKE_PATH || '/data/wake';
const TAG_PREFIX = 'obsidian-claude-assistant:';

const RECONNECT_MIN_MS = 2_000;
const RECONNECT_MAX_MS = 60_000;

let backoff = RECONNECT_MIN_MS;

const log = (...a) => console.log('[replies]', ...a);
const warn = (...a) => console.error('[replies]', ...a);

if (!SUPERVISOR_TOKEN) {
  warn('SUPERVISOR_TOKEN missing — cannot subscribe. Is homeassistant_api set?');
  process.exit(1);
}

function record(entry) {
  fs.appendFileSync(REPLIES, JSON.stringify(entry) + '\n');
  // attrib event: works even though the file's content never changes.
  const now = new Date();
  fs.utimesSync(WAKE, now, now);
  log(`queued ${entry.action} for ${entry.note}`);
}

// A tag only names a note when it is a plain relative path to a markdown file
// inside the vault. Everything else — our own error and stuck-file notices
// (`obsidian-claude-assistant:error`, `obsidian-claude-assistant:stuck:foo.md`), and anything malformed —
// is ignored. triage.sh interpolates this straight into "${VAULT}/${note}", so
// this is also the guard against escaping the vault.
function isNotePath(note) {
  return note.endsWith('.md')
    && !note.includes(':')
    && !note.startsWith('/')
    && !note.startsWith('.')
    && !note.split('/').includes('..')
    && !/[\0\n\r\\]/.test(note);
}

function handleEvent(data) {
  const tag = data?.tag;
  if (typeof tag !== 'string' || !tag.startsWith(TAG_PREFIX)) return;

  const note = tag.slice(TAG_PREFIX.length);
  if (!isNotePath(note)) return;

  record({
    note,
    action: data.action || 'REPLY',
    reply_text: data.reply_text ?? null,
    ts: new Date().toISOString(),
  });
}

function connect() {
  log(`connecting to ${WS_URL}`);
  let ws;
  try {
    ws = new WebSocket(WS_URL);
  } catch (e) {
    return retry(e.message);
  }

  let msgId = 1;
  let settled = false;

  ws.addEventListener('message', (event) => {
    let msg;
    try {
      msg = JSON.parse(event.data);
    } catch {
      return;
    }

    switch (msg.type) {
      case 'auth_required':
        ws.send(JSON.stringify({ type: 'auth', access_token: SUPERVISOR_TOKEN }));
        break;

      case 'auth_ok':
        log('authenticated, subscribing to mobile_app_notification_action');
        ws.send(JSON.stringify({
          id: msgId++,
          type: 'subscribe_events',
          event_type: 'mobile_app_notification_action',
        }));
        settled = true;
        backoff = RECONNECT_MIN_MS;
        break;

      case 'auth_invalid':
        warn('authentication rejected:', msg.message);
        ws.close();
        break;

      case 'result':
        if (!msg.success) warn('subscribe failed:', JSON.stringify(msg.error));
        else log('listening');
        break;

      case 'event':
        handleEvent(msg.event?.data);
        break;
    }
  });

  ws.addEventListener('error', (e) => warn('socket error:', e.message || 'unknown'));
  ws.addEventListener('close', () => retry(settled ? 'connection closed' : 'closed before auth'));
}

function retry(reason) {
  warn(`${reason}; reconnecting in ${Math.round(backoff / 1000)}s`);
  setTimeout(connect, backoff);
  backoff = Math.min(backoff * 2, RECONNECT_MAX_MS);
}

// Exported so the parsing can be tested without a live websocket.
module.exports = { handleEvent, record };

if (require.main === module) {
  for (const sig of ['SIGTERM', 'SIGINT']) {
    process.on(sig, () => { log('shutting down'); process.exit(0); });
  }
  connect();
}

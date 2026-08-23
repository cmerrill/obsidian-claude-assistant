#!/usr/bin/env node
// Listens for notification actions from the HA Companion app and hands them to
// the triage loop.
//
// Companion app -> mobile_app_notification_action event -> replies.jsonl
//                                                       -> touch /data/wake
//
// The shortcut notification's REPLY action is the one exception: it isn't
// tied to a note, so it skips replies.jsonl and writes straight into
// <vault>/inbox/ instead, same as a Drop box capture.
//
// Touching the wake file is what makes a reply feel instant: the triage loop is
// blocked on inotifywait against it, so it starts within a second instead of
// waiting out the poll interval.
//
// Node 22 ships a global WebSocket, so this has no dependencies.

const fs = require('fs');
const path = require('path');

const SUPERVISOR_TOKEN = process.env.SUPERVISOR_TOKEN;
const WS_URL = 'ws://supervisor/core/websocket';
// Overridable so the parsing can be exercised outside the container.
const REPLIES = process.env.REPLIES_PATH || '/data/replies.jsonl';
const WAKE = process.env.WAKE_PATH || '/data/wake';
const VAULT = process.env.VAULT || '/share/notes';
const TAG_PREFIX = 'obsidian-claude-assistant:';
const SHORTCUT_TAG = 'obsidian-claude-assistant:shortcut';

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

function wake() {
  if (!fs.existsSync(WAKE)) fs.closeSync(fs.openSync(WAKE, 'a'));
  const now = new Date();
  fs.utimesSync(WAKE, now, now);
}

// --- shortcut quick capture ---------------------------------------------
// The shortcut notification's REPLY action isn't tied to any note — it's a
// direct line into the inbox, so it bypasses replies.jsonl entirely and
// writes straight into the vault, the same way a Drop box capture does.
// slugify/timestamp/captureToInbox mirror slugify/timestamp/createInboxNote
// in web-ui.js's dropbox path, copied rather than shared (see the header
// comment on why these two daemons duplicate). Keep them in sync by hand.

function slugify(text, fallback) {
  const slug = (text || '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 60);
  return slug || fallback;
}

function timestamp() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}`
    + `-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`;
}

function captureToInbox(text) {
  const inbox = path.join(VAULT, 'inbox');
  fs.mkdirSync(inbox, { recursive: true, mode: 0o755 });

  const base = slugify(text.split(/\s+/).slice(0, 6).join(' '), 'capture');
  let name = `${base}-${timestamp()}.md`;
  for (let i = 1; fs.existsSync(path.join(inbox, name)); i++) {
    name = `${base}-${timestamp()}-${i}.md`;
  }
  const full = path.join(inbox, name);
  if (fs.realpathSync(path.dirname(full)) !== fs.realpathSync(inbox)) {
    warn(`refused capture path outside inbox/: ${name}`);
    return;
  }

  fs.writeFileSync(full, text.trim() + '\n', { mode: 0o644 });
  wake();
  log(`captured inbox/${name} from shortcut`);
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

  if (tag === SHORTCUT_TAG) {
    if (typeof data.reply_text === 'string' && data.reply_text.trim()) {
      captureToInbox(data.reply_text);
    }
    return;
  }

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
module.exports = { handleEvent, record, captureToInbox };

if (require.main === module) {
  for (const sig of ['SIGTERM', 'SIGINT']) {
    process.on(sig, () => { log('shutting down'); process.exit(0); });
  }
  connect();
}

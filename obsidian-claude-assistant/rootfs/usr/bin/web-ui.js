#!/usr/bin/env node
// Ingress web page: pending questions, long replies, file uploads, drop box.
//
//   phone/browser -> HA ingress proxy (172.30.32.2) -> this server (:8099)
//
// Replies land in the same replies.jsonl + /data/wake pipeline the
// notification listener uses, so triage.sh drains them identically no matter
// which surface answered. Uploads land in <vault>/attachments/ where git and
// Obsidian Sync pick them up on their own; files ticked "delete after
// processing" are recorded in ephemeral.json for triage.sh to remove once the
// owning note is resolved or filed.
//
// This server only ever CREATES vault files (uploads, inbox captures, spill
// files). It never rewrites an existing one — all frontmatter mutation stays
// in triage.sh, which is also why the replace_file() permission hazard
// documented there does not apply here: a brand-new file is written directly
// at its final path with an explicit 0644.
//
// Dependency-free on purpose, like reply-listener.js. The two daemons share
// the shape of isNotePath() and the reply record by copy, not by require, so
// each stays independently restartable.

const { execFile } = require('child_process');
const fs = require('fs');
const http = require('http');
const path = require('path');

// Overridable so everything can be exercised outside the container.
const VAULT = process.env.VAULT || '/share/notes';
const REPLIES = process.env.REPLIES_PATH || '/data/replies.jsonl';
const PENDING = process.env.PENDING_PATH || '/data/replies.processing.jsonl';
const WAKE = process.env.WAKE_PATH || '/data/wake';
const EPHEMERAL = process.env.EPHEMERAL_PATH || '/data/ephemeral.json';
const PORT = Number(process.env.WEB_PORT || 8099);
// Ingress connections come from HA's proxy and nowhere else; there is no
// ports: mapping, so anything from another address is a neighbor container
// poking around. WEB_ALLOW_ANY=1 disables the check for local testing.
const INGRESS_PROXY = '172.30.32.2';
const ALLOW_ANY = process.env.WEB_ALLOW_ANY === '1';

const MAX_UPLOAD_BYTES = 50 * 1024 * 1024;
const MAX_JSON_BYTES = 1024 * 1024;
// A reply longer than this is written to a file instead of inlined: the text
// ends up inside a claude -p argument, and keeping appended jsonl lines small
// is also what keeps concurrent O_APPEND writes with reply-listener.js atomic
// in practice.
const MAX_INLINE_REPLY = 4096;

const ATTACH_DIR = 'attachments';

// The ongoing shortcut notification. notify.sh owns the payload and the
// opt-in check; this file only decides *when* to (re-)post it. NOTIFY is
// overridable so the timing can be exercised with a stub outside the container.
const NOTIFY = process.env.NOTIFY_BIN || '/usr/bin/notify.sh';
const SHORTCUT_TAG = 'obsidian-claude-assistant:shortcut';
const SHORTCUT_ENABLED = process.env.PERSISTENT_SHORTCUT === 'true';
// Collapses the burst of reloads around one visit. Nothing breaks without it —
// re-posting under a fixed tag is a silent replace — it just keeps the log
// readable when a page is refreshed a few times in a row.
const SHORTCUT_MIN_INTERVAL_MS = 30 * 1000;

const log = (...a) => console.log('[web]', ...a);
const warn = (...a) => console.error('[web]', ...a);

// --- the ongoing shortcut ----------------------------------------------------
// A persistent notification lives on the phone, not here, so nothing in this
// container can tell whether it is still there. It survives an add-on restart
// and dies with a phone reboot, an app update, or an Android 14 swipe.
//
// Re-posting on every triage cycle would keep it alive but spend a service call
// every few minutes forever to fix something that almost never breaks. Opening
// the page is the better trigger: it is the moment the phone is in hand, and
// the one moment the shortcut being gone is both provable and worth fixing —
// you just had to reach the page some other way.
//
// The gap is a shortcut lost while the page goes unopened. That is survivable
// by design: the sidebar entry it duplicates never goes anywhere.

let shortcutSentAt = 0;

function notify(args, what) {
  execFile(NOTIFY, args, (err, stdout, stderr) => {
    if (err) warn(`${what} failed:`, (stderr || err.message).trim());
    else if (stderr.trim()) warn(`${what}:`, stderr.trim());
  });
}

function refreshShortcut(force) {
  if (!SHORTCUT_ENABLED) return;
  const now = Date.now();
  if (!force && now - shortcutSentAt < SHORTCUT_MIN_INTERVAL_MS) return;
  shortcutSentAt = now;
  notify(['shortcut'], 'shortcut post');
}

// Turning the option off restarts the add-on but cannot reach into the shade,
// and the notification it leaves behind is the non-dismissible kind. Clearing
// the tag on every disabled start is what makes the option reversible.
function syncShortcutOnStart() {
  if (SHORTCUT_ENABLED) refreshShortcut(true);
  else notify(['clear', SHORTCUT_TAG], 'shortcut clear');
}

// --- shared shapes (copied from reply-listener.js, keep in sync) -------------

// triage.sh interpolates this straight into "${VAULT}/${note}", so this is
// the guard against escaping the vault.
function isNotePath(note) {
  return typeof note === 'string'
    && note.endsWith('.md')
    && !note.includes(':')
    && !note.startsWith('/')
    && !note.startsWith('.')
    && !note.split('/').includes('..')
    && !/[\0\n\r\\]/.test(note);
}

function record(entry) {
  fs.appendFileSync(REPLIES, JSON.stringify(entry) + '\n');
  // attrib event: works even though the file's content never changes.
  if (!fs.existsSync(WAKE)) fs.closeSync(fs.openSync(WAKE, 'a'));
  const now = new Date();
  fs.utimesSync(WAKE, now, now);
  log(`queued ${entry.action} for ${entry.note}`);
}

// --- vault reading -----------------------------------------------------------

// First --- block only, one key per call would be wasteful here, so parse the
// whole block. Strips a trailing CR per line: the vault is edited from
// Windows Obsidian, and "true\r" must still read as "true".
function parseFrontmatter(content) {
  const lines = content.split('\n').map((l) => l.replace(/\r$/, ''));
  if (lines[0] !== '---') return {};
  const fm = {};
  for (let i = 1; i < lines.length; i++) {
    if (lines[i] === '---') break;
    const m = lines[i].match(/^([^:]+):\s*(.*)$/);
    if (m) fm[m[1].trim()] = m[2].trim().replace(/^"|"$/g, '');
  }
  return fm;
}

// The full "## Open questions" section, up to the next heading. The page has
// room, so no 430-byte notification cap here.
function openQuestions(content) {
  const lines = content.split('\n').map((l) => l.replace(/\r$/, ''));
  const out = [];
  let inside = false;
  for (const line of lines) {
    if (/^##\s+open questions\s*$/i.test(line)) { inside = true; continue; }
    if (inside && /^##?\s/.test(line)) break;
    if (inside) out.push(line);
  }
  return out.join('\n').trim();
}

// Mirror of triage.sh flagged_notes(): a cheap substring test narrows the
// candidates, the frontmatter parse is the real check. .claude and templates
// both contain the literal string as documentation.
function scanFlagged() {
  const flagged = [];
  const walk = (dir) => {
    let entries;
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const e of entries) {
      if (e.name.startsWith('.') || e.name === 'templates') continue;
      const full = path.join(dir, e.name);
      if (e.isDirectory()) {
        walk(full);
      } else if (e.isFile() && e.name.endsWith('.md')) {
        let content;
        try {
          content = fs.readFileSync(full, 'utf8');
        } catch {
          continue;
        }
        if (!content.includes('needs-review: true')) continue;
        const fm = parseFrontmatter(content);
        if (fm['needs-review'] !== 'true' || fm['review-stopped'] === 'true') continue;
        flagged.push({
          note: path.relative(VAULT, full),
          round: fm['review-round'] || '1',
          question: openQuestions(content),
        });
      }
    }
  };
  walk(VAULT);
  flagged.sort((a, b) => a.note.localeCompare(b.note));
  return flagged;
}

// Notes with an answer already sitting in the queue. Shown as "queued" with
// the buttons disabled, so a slow drain doesn't invite a duplicate answer.
function queuedNotes() {
  const notes = new Set();
  for (const file of [REPLIES, PENDING]) {
    let text;
    try {
      text = fs.readFileSync(file, 'utf8');
    } catch {
      continue;
    }
    for (const line of text.split('\n')) {
      if (!line.trim()) continue;
      try {
        const entry = JSON.parse(line);
        if (entry.note) notes.add(entry.note);
      } catch { /* a torn line is the drain's problem, not ours */ }
    }
  }
  return notes;
}

// --- vault writing -----------------------------------------------------------

// What a file may be called inside attachments/. Same philosophy as
// inbox-done.sh: constrain the name first, then verify where the final path
// really resolves — never trust a prefix match.
function safeAttachmentName(raw) {
  let name;
  try {
    name = decodeURIComponent(raw || '');
  } catch {
    return null;
  }
  name = path.basename(name.replace(/\\/g, '/'))
    .replace(/[^A-Za-z0-9._ -]+/g, ' ')
    .replace(/\s+/g, ' ')
    .replace(/ ?\. ?/g, '.')
    .trim();
  if (!name || name.startsWith('.') || !/\.[A-Za-z0-9]+$/.test(name)) return null;
  if (name.length > 100) {
    const ext = name.slice(name.lastIndexOf('.'));
    name = name.slice(0, 100 - ext.length) + ext;
  }
  return name;
}

// Resolve-then-check: the parent of the path we are about to write must BE
// the attachments dir, not merely start with its name.
function attachmentTarget(name) {
  const dir = path.join(VAULT, ATTACH_DIR);
  fs.mkdirSync(dir, { recursive: true, mode: 0o755 });
  if (fs.realpathSync(path.dirname(path.join(dir, name))) !== fs.realpathSync(dir)) {
    return null;
  }
  let candidate = name;
  const ext = name.slice(name.lastIndexOf('.'));
  const stem = name.slice(0, name.lastIndexOf('.'));
  for (let i = 1; fs.existsSync(path.join(dir, candidate)); i++) {
    if (i > 50) { candidate = `${stem}-${Date.now()}${ext}`; break; }
    candidate = `${stem}-${i}${ext}`;
  }
  return { full: path.join(dir, candidate), rel: `${ATTACH_DIR}/${candidate}` };
}

// A vault-relative attachment path as echoed back by the client. Constrained
// to exactly the names safeAttachmentName can produce.
function isAttachmentPath(p) {
  return typeof p === 'string'
    && /^attachments\/[A-Za-z0-9_-][A-Za-z0-9._ -]*$/.test(p)
    && !p.split('/')[1].startsWith('.');
}

// Owner note -> files to delete once the note is resolved. triage.sh prunes
// entries as it deletes; a concurrent read-modify-write here could briefly
// resurrect one, which is harmless — cleanup re-checks the owner next cycle
// and a missing file deletes as a no-op.
function addEphemeral(owner, paths) {
  if (!paths.length) return;
  let state = {};
  try {
    state = JSON.parse(fs.readFileSync(EPHEMERAL, 'utf8'));
  } catch { /* seeded by init-config; dev runs start empty */ }
  state[owner] = [...new Set([...(state[owner] || []), ...paths])];
  // New file each time would drop the 0644 the seed gave it; write through.
  fs.writeFileSync(EPHEMERAL, JSON.stringify(state, null, 2) + '\n');
}

function attachmentLines(attachments, ephemeral) {
  return attachments.map((p) => {
    const temp = ephemeral.includes(p)
      ? ' — this file is temporary and will be deleted after processing, so extract what you need from it rather than linking to it'
      : '';
    return `Attached file (read it with the Read tool): ${p}${temp}`;
  });
}

function buildReplyText(text, attachments, ephemeral, noteBase) {
  const parts = [];
  if (text.trim()) parts.push(text.trim());
  parts.push(...attachmentLines(attachments, ephemeral));
  let replyText = parts.join('\n');
  if (replyText.length > MAX_INLINE_REPLY) {
    const name = safeAttachmentName(`reply-${noteBase}-${Date.now()}.md`);
    const target = name && attachmentTarget(name);
    if (target) {
      fs.writeFileSync(target.full, replyText + '\n', { mode: 0o644 });
      replyText = `Long reply saved to ${target.rel} — read it with the Read tool.`
        + (ephemeral.length ? ' Some attached files are temporary; the saved reply says which.' : '');
    }
  }
  return replyText;
}

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

function createInboxNote({ title, text, attachments, ephemeral }) {
  const inbox = path.join(VAULT, 'inbox');
  fs.mkdirSync(inbox, { recursive: true, mode: 0o755 });

  const base = slugify(title || (text || '').split(/\s+/).slice(0, 6).join(' '), 'capture');
  let name = `${base}-${timestamp()}.md`;
  for (let i = 1; fs.existsSync(path.join(inbox, name)); i++) {
    name = `${base}-${timestamp()}-${i}.md`;
  }
  if (fs.realpathSync(path.dirname(path.join(inbox, name))) !== fs.realpathSync(inbox)) {
    return null;
  }

  const body = [];
  if (title) body.push(`# ${title}`, '');
  if (text.trim()) body.push(text.trim(), '');
  for (const p of attachments) {
    // The embed is for a human opening the capture in Obsidian; the plain
    // labelled path line is what the triage prompt acts on.
    body.push(`![[${p}]]`);
  }
  if (attachments.length) body.push('');
  body.push(...attachmentLines(attachments, ephemeral));

  const full = path.join(inbox, name);
  fs.writeFileSync(full, body.join('\n').trim() + '\n', { mode: 0o644 });
  return `inbox/${name}`;
}

// --- page --------------------------------------------------------------------

function escapeHtml(s) {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

// All fetch() targets are relative on purpose: ingress serves this page under
// /api/hassio_ingress/<token>/, and relative URLs are the one form that needs
// no knowledge of that prefix.
const CLIENT_JS = `
(function () {
  'use strict';

  function renderFileList(input, listEl) {
    listEl.textContent = '';
    Array.prototype.forEach.call(input.files, function (file, i) {
      var row = document.createElement('label');
      row.className = 'filerow';
      var box = document.createElement('input');
      box.type = 'checkbox';
      box.dataset.index = i;
      row.appendChild(box);
      row.appendChild(document.createTextNode(
        ' ' + file.name + ' — delete after processing'));
      listEl.appendChild(row);
    });
  }

  function uploadAll(input, listEl, onProgress) {
    var files = Array.prototype.slice.call(input.files);
    var ticked = {};
    listEl.querySelectorAll('input[type=checkbox]').forEach(function (box) {
      if (box.checked) ticked[box.dataset.index] = true;
    });
    var paths = [];
    var ephemeral = [];
    var chain = Promise.resolve();
    files.forEach(function (file, i) {
      chain = chain.then(function () {
        onProgress('Uploading ' + file.name + '\\u2026');
        return fetch('api/upload', {
          method: 'POST',
          body: file,
          headers: { 'X-Filename': encodeURIComponent(file.name) }
        }).then(function (res) {
          if (!res.ok) throw new Error('upload of ' + file.name + ' failed (' + res.status + ')');
          return res.json();
        }).then(function (data) {
          paths.push(data.path);
          if (ticked[i]) ephemeral.push(data.path);
        });
      });
    });
    return chain.then(function () { return { paths: paths, ephemeral: ephemeral }; });
  }

  function postJson(url, body) {
    return fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body)
    }).then(function (res) {
      if (!res.ok) {
        return res.json().catch(function () { return {}; }).then(function (data) {
          throw new Error(data.error || ('request failed (' + res.status + ')'));
        });
      }
    });
  }

  function wireCard(card) {
    var note = card.dataset.note;
    var input = card.querySelector('input[type=file]');
    var listEl = card.querySelector('.filelist');
    var status = card.querySelector('.status');
    var buttons = card.querySelectorAll('button');

    if (input) {
      input.addEventListener('change', function () { renderFileList(input, listEl); });
    }

    function finish(label) {
      buttons.forEach(function (b) { b.disabled = true; });
      status.textContent = label;
      setTimeout(function () { location.reload(); }, 1200);
    }

    function fail(err) {
      buttons.forEach(function (b) { b.disabled = false; });
      status.textContent = err.message;
    }

    card.addEventListener('click', function (ev) {
      var action = ev.target.dataset && ev.target.dataset.action;
      if (!action) return;
      buttons.forEach(function (b) { b.disabled = true; });

      if (action === 'CLAUDE_STOP' && !confirm('Stop asking about this note?')) {
        buttons.forEach(function (b) { b.disabled = false; });
        return;
      }

      var setStatus = function (s) { status.textContent = s; };
      var uploads = (action === 'REPLY' && input && input.files.length)
        ? uploadAll(input, listEl, setStatus)
        : Promise.resolve({ paths: [], ephemeral: [] });

      uploads.then(function (up) {
        setStatus('Sending\\u2026');
        return postJson('api/reply', {
          note: note,
          action: action,
          text: action === 'REPLY' ? card.querySelector('textarea').value : '',
          attachments: up.paths,
          ephemeral: up.ephemeral
        });
      }).then(function () {
        finish('Queued — applied within about a minute.');
      }).catch(fail);
    });
  }

  document.querySelectorAll('.card[data-note]').forEach(wireCard);

  var drop = document.getElementById('dropbox');
  if (drop) {
    var input = drop.querySelector('input[type=file]');
    var listEl = drop.querySelector('.filelist');
    var status = drop.querySelector('.status');
    var button = drop.querySelector('button');
    input.addEventListener('change', function () { renderFileList(input, listEl); });
    button.addEventListener('click', function () {
      var text = drop.querySelector('textarea').value;
      var title = drop.querySelector('input[type=text]').value;
      if (!text.trim() && !input.files.length) {
        status.textContent = 'Nothing to send.';
        return;
      }
      button.disabled = true;
      var setStatus = function (s) { status.textContent = s; };
      var uploads = input.files.length
        ? uploadAll(input, listEl, setStatus)
        : Promise.resolve({ paths: [], ephemeral: [] });
      uploads.then(function (up) {
        setStatus('Sending\\u2026');
        return postJson('api/dropbox', {
          title: title, text: text,
          attachments: up.paths, ephemeral: up.ephemeral
        });
      }).then(function () {
        status.textContent = 'Dropped into inbox — triaged on the next cycle.';
        setTimeout(function () { location.reload(); }, 1500);
      }).catch(function (err) {
        button.disabled = false;
        status.textContent = err.message;
      });
    });
  }
})();
`;

const CSS = `
:root { color-scheme: light dark; }
* { box-sizing: border-box; }
body {
  margin: 0; padding: 12px; max-width: 720px; margin-inline: auto;
  font: 16px/1.45 system-ui, sans-serif;
  background: Canvas; color: CanvasText;
}
h1 { font-size: 1.2rem; margin: 8px 0 16px; }
.card {
  border: 1px solid color-mix(in srgb, CanvasText 22%, Canvas);
  border-radius: 10px; padding: 14px; margin-bottom: 16px;
}
.card h2 { font-size: 1rem; margin: 0 0 2px; overflow-wrap: anywhere; }
.meta { font-size: .8rem; opacity: .7; margin-bottom: 8px; }
.question {
  white-space: pre-wrap; overflow-wrap: anywhere;
  background: color-mix(in srgb, CanvasText 6%, Canvas);
  border-radius: 6px; padding: 10px; font-size: .95rem; margin-bottom: 10px;
}
textarea, input[type=text] {
  width: 100%; font: inherit; padding: 8px; margin-bottom: 8px;
  border: 1px solid color-mix(in srgb, CanvasText 30%, Canvas);
  border-radius: 6px; background: Field; color: FieldText;
}
textarea { min-height: 5.5em; resize: vertical; }
input[type=file] { margin-bottom: 8px; max-width: 100%; }
.filerow { display: block; font-size: .85rem; margin: 2px 0 6px; }
.buttons { display: flex; gap: 8px; flex-wrap: wrap; }
button {
  font: inherit; padding: 8px 14px; border-radius: 6px; cursor: pointer;
  border: 1px solid color-mix(in srgb, CanvasText 30%, Canvas);
  background: color-mix(in srgb, CanvasText 8%, Canvas); color: CanvasText;
}
button.primary { background: #2563eb; border-color: #2563eb; color: #fff; }
button:disabled { opacity: .5; cursor: default; }
.status { font-size: .85rem; margin-top: 8px; min-height: 1.2em; }
.queued { opacity: .65; }
.empty { opacity: .7; font-style: italic; margin-bottom: 16px; }
`;

function renderPage() {
  const flagged = scanFlagged();
  const queued = queuedNotes();

  const cards = flagged.map(({ note, round, question }) => {
    const isQueued = queued.has(note);
    const name = escapeHtml(path.basename(note, '.md'));
    const q = escapeHtml(question || 'Needs a look — no question recorded.');
    if (isQueued) {
      return `<div class="card queued"><h2>${name}</h2>
<div class="meta">${escapeHtml(note)} · round ${escapeHtml(round)}</div>
<div class="question">${q}</div>
<div class="status">Answer queued — applied within about a minute.</div></div>`;
    }
    return `<div class="card" data-note="${escapeHtml(note)}"><h2>${name}</h2>
<div class="meta">${escapeHtml(note)} · round ${escapeHtml(round)}</div>
<div class="question">${q}</div>
<textarea placeholder="Your answer — paste as much as you need"></textarea>
<input type="file" multiple>
<div class="filelist"></div>
<div class="buttons">
<button class="primary" data-action="REPLY">Send reply</button>
<button data-action="CLAUDE_OK">Looks good</button>
<button data-action="CLAUDE_STOP">Stop asking</button>
</div>
<div class="status"></div></div>`;
  });

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Claude Assistant</title>
<style>${CSS}</style>
</head>
<body>
<h1>Pending questions</h1>
${cards.join('\n') || '<p class="empty">Nothing waiting on you.</p>'}
<h1>Drop box</h1>
<div class="card" id="dropbox">
<input type="text" placeholder="Title (optional)">
<textarea placeholder="Paste text, a recipe, anything — it lands in inbox/ for triage"></textarea>
<input type="file" multiple>
<div class="filelist"></div>
<div class="buttons"><button class="primary">Send to inbox</button></div>
<div class="status"></div>
</div>
<script>${CLIENT_JS}</script>
</body>
</html>`;
}

// --- request handling --------------------------------------------------------

function sendJson(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, { 'Content-Type': 'application/json' });
  res.end(body);
}

function allowedSource(req) {
  if (ALLOW_ANY) return true;
  const addr = req.socket.remoteAddress || '';
  return addr === INGRESS_PROXY || addr === `::ffff:${INGRESS_PROXY}`
    || addr === '127.0.0.1' || addr === '::1';
}

function readJsonBody(req, cb) {
  const chunks = [];
  let size = 0;
  req.on('data', (chunk) => {
    size += chunk.length;
    if (size > MAX_JSON_BYTES) {
      req.destroy();
      return;
    }
    chunks.push(chunk);
  });
  req.on('end', () => {
    try {
      cb(null, JSON.parse(Buffer.concat(chunks).toString('utf8')));
    } catch (e) {
      cb(e);
    }
  });
  req.on('error', (e) => cb(e));
}

function handleUpload(req, res) {
  const name = safeAttachmentName(req.headers['x-filename']);
  if (!name) return sendJson(res, 400, { error: 'bad or missing X-Filename' });

  let target;
  try {
    target = attachmentTarget(name);
  } catch (e) {
    warn('upload target failed:', e.message);
    return sendJson(res, 500, { error: 'could not prepare attachments/' });
  }
  if (!target) return sendJson(res, 400, { error: 'refused path' });

  const out = fs.createWriteStream(target.full, { flags: 'wx', mode: 0o644 });
  let size = 0;
  let failed = false;

  // Answer first, then cut the connection: destroying the request outright
  // shares a socket with the response, so the client would see a reset
  // instead of the 413. The destroy after flush is what stops a client from
  // pushing the remaining megabytes into a dead upload.
  const abort = (code, msg) => {
    if (failed) return;
    failed = true;
    req.unpipe(out);
    out.destroy();
    fs.unlink(target.full, () => {});
    res.writeHead(code, { 'Content-Type': 'application/json', Connection: 'close' });
    res.end(JSON.stringify({ error: msg }), () => req.destroy());
  };

  req.on('data', (chunk) => {
    size += chunk.length;
    if (size > MAX_UPLOAD_BYTES) abort(413, 'file too large');
  });
  req.on('error', () => abort(400, 'upload interrupted'));
  out.on('error', (e) => { warn('write failed:', e.message); abort(500, 'write failed'); });
  out.on('finish', () => {
    if (failed) return;
    log(`stored ${target.rel} (${size} bytes)`);
    sendJson(res, 200, { path: target.rel });
  });
  req.pipe(out);
}

function validAttachmentList(list) {
  return Array.isArray(list) && list.length <= 20 && list.every(isAttachmentPath);
}

function handleReply(req, res) {
  readJsonBody(req, (err, body) => {
    if (err) return sendJson(res, 400, { error: 'bad JSON' });
    const { note, action } = body;
    const text = typeof body.text === 'string' ? body.text : '';
    const attachments = body.attachments || [];
    const ephemeral = body.ephemeral || [];

    if (!['REPLY', 'CLAUDE_OK', 'CLAUDE_STOP'].includes(action)) {
      return sendJson(res, 400, { error: 'bad action' });
    }
    if (!isNotePath(note)) return sendJson(res, 400, { error: 'bad note path' });
    if (!validAttachmentList(attachments) || !validAttachmentList(ephemeral)
        || !ephemeral.every((p) => attachments.includes(p))) {
      return sendJson(res, 400, { error: 'bad attachment list' });
    }

    // A stale page must not queue answers for a note that moved on.
    let content;
    try {
      content = fs.readFileSync(path.join(VAULT, note), 'utf8');
    } catch {
      return sendJson(res, 409, { error: 'note no longer exists' });
    }
    const fm = parseFrontmatter(content);
    if (fm['needs-review'] !== 'true' || fm['review-stopped'] === 'true') {
      return sendJson(res, 409, { error: 'note is no longer awaiting review' });
    }

    let replyText = null;
    if (action === 'REPLY') {
      if (!text.trim() && !attachments.length) {
        return sendJson(res, 400, { error: 'empty reply' });
      }
      try {
        replyText = buildReplyText(text, attachments, ephemeral, path.basename(note, '.md'));
      } catch (e) {
        warn('spill failed:', e.message);
        return sendJson(res, 500, { error: 'could not store reply' });
      }
    }

    try {
      addEphemeral(note, ephemeral);
      record({ note, action, reply_text: replyText, ts: new Date().toISOString() });
    } catch (e) {
      warn('queue failed:', e.message);
      return sendJson(res, 500, { error: 'could not queue reply' });
    }
    sendJson(res, 200, { ok: true });
  });
}

function handleDropbox(req, res) {
  readJsonBody(req, (err, body) => {
    if (err) return sendJson(res, 400, { error: 'bad JSON' });
    const title = typeof body.title === 'string' ? body.title.slice(0, 200) : '';
    const text = typeof body.text === 'string' ? body.text : '';
    const attachments = body.attachments || [];
    const ephemeral = body.ephemeral || [];

    if (!validAttachmentList(attachments) || !validAttachmentList(ephemeral)
        || !ephemeral.every((p) => attachments.includes(p))) {
      return sendJson(res, 400, { error: 'bad attachment list' });
    }
    if (!title.trim() && !text.trim() && !attachments.length) {
      return sendJson(res, 400, { error: 'nothing to capture' });
    }

    let notePath;
    try {
      notePath = createInboxNote({ title, text, attachments, ephemeral });
    } catch (e) {
      warn('capture failed:', e.message);
      return sendJson(res, 500, { error: 'could not write inbox note' });
    }
    if (!notePath) return sendJson(res, 400, { error: 'refused path' });

    try {
      addEphemeral(notePath, ephemeral);
      // Wake the loop: the note itself waits out INBOX_SETTLE_MINUTES, but the
      // cycle's first act is committing inbound files to git, which is the
      // same durability the notification path gets.
      if (!fs.existsSync(WAKE)) fs.closeSync(fs.openSync(WAKE, 'a'));
      const now = new Date();
      fs.utimesSync(WAKE, now, now);
    } catch (e) {
      warn('post-capture bookkeeping failed:', e.message);
    }
    log(`captured ${notePath} (${attachments.length} attachment(s))`);
    sendJson(res, 200, { ok: true, note: notePath });
  });
}

function handle(req, res) {
  if (!allowedSource(req)) {
    warn(`refused ${req.method} ${req.url} from ${req.socket.remoteAddress}`);
    res.writeHead(403);
    return res.end('ingress only');
  }
  const url = (req.url || '/').split('?')[0];

  if (req.method === 'GET' && url === '/') {
    // Only the page itself, not the API routes it calls afterwards: one visit
    // should mean one re-post, not one per button press.
    refreshShortcut(false);
    const html = renderPage();
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    return res.end(html);
  }
  if (req.method === 'POST' && url === '/api/upload') return handleUpload(req, res);
  if (req.method === 'POST' && url === '/api/reply') return handleReply(req, res);
  if (req.method === 'POST' && url === '/api/dropbox') return handleDropbox(req, res);

  res.writeHead(404);
  res.end('not found');
}

// Exported so the parsing and path rules can be tested without a server.
module.exports = {
  isNotePath,
  safeAttachmentName,
  isAttachmentPath,
  parseFrontmatter,
  openQuestions,
  scanFlagged,
  buildReplyText,
  createInboxNote,
};

if (require.main === module) {
  for (const sig of ['SIGTERM', 'SIGINT']) {
    process.on(sig, () => { log('shutting down'); process.exit(0); });
  }
  http.createServer((req, res) => {
    try {
      handle(req, res);
    } catch (e) {
      warn('unhandled:', e.stack || e.message);
      if (!res.headersSent) res.writeHead(500);
      res.end();
    }
  }).listen(PORT, '0.0.0.0', () => {
    log(`listening on :${PORT}`);
    syncShortcutOnStart();
  });
}

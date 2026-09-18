// Help page — a plain-language install/troubleshooting guide, reached from the popup footer.
// No rules-core.js/rules-lib.js here on purpose: this page needs no story data, only the native
// host's connectivity (the same 'pingNativeHost' message options.js already uses) and the
// extension's own id (chrome.runtime.id — the one thing an extension can always know about its
// own install for certain, same reasoning options.js's checkHostStatus() comment already gives).
console.log('[stg-help] help build: v1');

const $ = (s) => document.querySelector(s);
const send = (msg) => new Promise((r) => chrome.runtime.sendMessage(msg, r));

async function checkLiveStatus() {
  const el = $('#liveStatus');
  el.textContent = 'Checking…';
  let res;
  try { res = await send({ type: 'pingNativeHost' }); } catch (e) { res = { ok: false, error: String(e) }; }

  el.innerHTML = '';
  if (res && res.ok && res.pong) {
    const pill = document.createElement('span'); pill.className = 'pill gen'; pill.textContent = '✓ connected';
    const note = document.createElement('span'); note.className = 'note'; note.style.margin = '0';
    note.textContent = "You're all set — no further setup needed.";
    el.append(pill, note);
    return;
  }
  const pill = document.createElement('span'); pill.className = 'pill err'; pill.textContent = '✕ not connected';
  const note = document.createElement('span'); note.className = 'note'; note.style.margin = '0';
  note.textContent = 'Follow First-time setup below.';
  el.append(pill, note);
}

// Fills in the Advanced (manual install) command with this extension's real id, so it's ready to
// copy-paste without a trip to chrome://extensions to look it up.
function fillManualCommand() {
  const myId = chrome.runtime.id;
  const cmd = `cd native-host\n.\\install-native-host.ps1 -ExtensionId ${myId}`;
  $('#manualCmd').textContent = cmd;
  $('#manualIdNote').textContent = `(this extension's id: ${myId} — already filled in above)`;
  $('#manualCopyBtn').onclick = () => copyText(cmd, $('#manualCopyMsg'));
}

async function copyText(text, msgEl) {
  try {
    await navigator.clipboard.writeText(text);
    msgEl.textContent = 'Copied ✓';
    setTimeout(() => { msgEl.textContent = ''; }, 1600);
  } catch (e) {
    msgEl.textContent = 'Copy failed — select the text and copy manually';
  }
}

// Every other Copy button just carries its exact command in data-copy — declared statically in
// help.html, so one delegated handler covers all of them.
document.addEventListener('click', (e) => {
  const btn = e.target.closest('[data-copy]');
  if (!btn) return;
  const msgEl = document.getElementById(btn.dataset.copymsg);
  copyText(btn.dataset.copy, msgEl);
});

checkLiveStatus();
fillManualCommand();

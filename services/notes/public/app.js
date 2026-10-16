// Inbox page: add links/notes from any browser (handy on a phone) and see what's queued.

const $ = (id) => document.getElementById(id);
const KIND_LABELS = { x_post: 'X post', article: 'Article', note: 'Note' };

function token() {
  try { return localStorage.getItem('notesToken') || ''; } catch { return ''; }
}

function saveToken(value) {
  try { localStorage.setItem('notesToken', value); } catch { /* private mode: ask again next time */ }
}

async function api(path, options = {}) {
  const headers = { 'Content-Type': 'application/json', ...(options.headers || {}) };
  if (token()) headers.Authorization = `Bearer ${token()}`;
  const res = await fetch(path, { ...options, headers });
  if (res.status === 401) {
    const entered = prompt('Enter the notes service token');
    if (entered) {
      saveToken(entered.trim());
      return api(path, options);
    }
  }
  if (res.status === 204) return null;
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
  return data;
}

function showMessage(text, isError = false) {
  $('msg').textContent = text;
  $('msg').className = isError ? 'msg error' : 'msg';
}

function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  Object.entries(attrs).forEach(([k, v]) => (k === 'className' ? (node.className = v) : node.setAttribute(k, v)));
  children.filter(Boolean).forEach((c) => node.append(c));
  return node;
}

function render(items) {
  $('count').textContent = items.length ? `${items.length} queued` : '';
  const list = $('list');
  list.replaceChildren();
  if (!items.length) {
    list.append(el('li', { className: 'empty' }, 'Nothing in the inbox.'));
    return;
  }
  for (const item of items) {
    const del = el('button', { className: 'del', type: 'button' }, 'Delete');
    del.onclick = async () => {
      if (!confirm(`Delete "${item.title}"?`)) return;
      try {
        await api(`/api/items/${item.id}`, { method: 'DELETE' });
        load();
      } catch (err) {
        showMessage(err.message, true);
      }
    };
    const added = new Date(item.createdAt).toLocaleString([], { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
    list.append(el('li', {},
      el('div', { className: 'top' },
        el('div', { className: 'title' }, item.title),
        el('span', { className: `kind ${item.kind}` }, KIND_LABELS[item.kind] || item.kind)),
      item.body ? el('div', { className: 'body' }, item.body) : null,
      el('div', { className: 'meta' },
        el('span', {}, added),
        item.url ? el('a', { href: item.url, target: '_blank', rel: 'noopener' }, item.source || 'Open') : null,
        del)));
  }
}

async function load() {
  try {
    render(await api('/api/items'));
  } catch (err) {
    showMessage(err.message, true);
  }
}

$('add').addEventListener('submit', async (event) => {
  event.preventDefault();
  const input = $('input').value.trim();
  if (!input) return;
  $('submit').disabled = true;
  showMessage('Adding…');
  try {
    const item = await api('/api/items', { method: 'POST', body: JSON.stringify({ input }) });
    $('input').value = '';
    showMessage(`Added: ${item.title}`);
    load();
  } catch (err) {
    showMessage(err.message, true);
  } finally {
    $('submit').disabled = false;
  }
});

load();

// Inbox page: add links/notes from any browser (handy on a phone) and browse everything ever saved.

const $ = (id) => document.getElementById(id);
const KIND_LABELS = { x_post: 'X post', article: 'Article', note: 'Note' };
const STATUS_LABELS = { used: 'Used', dismissed: 'Removed from queue' };
const FILTERS = {
  all: () => true,
  inbox: (item) => item.status === 'inbox',
  used: (item) => item.status === 'used',
};

let items = [];
let filter = 'all';

// The browser handles the login (HTTP Basic) and resends it with every request.
async function api(path, options = {}) {
  const res = await fetch(path, {
    ...options,
    headers: { 'Content-Type': 'application/json', ...(options.headers || {}) },
  });
  if (res.status === 401) throw new Error('Not logged in. Reload the page to log in.');
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

function button(label, className, onClick) {
  const node = el('button', { className, type: 'button' }, label);
  node.onclick = onClick;
  return node;
}

/** "Today", "Yesterday", or e.g. "Tuesday, September 8, 2026" — the day an item was saved. */
function dayLabel(date) {
  const startOf = (d) => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
  const days = Math.round((startOf(new Date()) - startOf(date)) / 86400000);
  if (days === 0) return 'Today';
  if (days === 1) return 'Yesterday';
  return date.toLocaleDateString([], { weekday: 'long', month: 'long', day: 'numeric', year: 'numeric' });
}

async function setStatus(item, status) {
  try {
    await api(`/api/items/${item.id}`, { method: 'PATCH', body: JSON.stringify({ status }) });
    load();
  } catch (err) {
    showMessage(err.message, true);
  }
}

async function remove(item) {
  if (!confirm(`Permanently delete "${item.title}" from your history?`)) return;
  try {
    await api(`/api/items/${item.id}`, { method: 'DELETE' });
    load();
  } catch (err) {
    showMessage(err.message, true);
  }
}

function card(item) {
  const time = new Date(item.createdAt).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
  const actions = item.status === 'inbox'
    ? null
    : button('Back to queue', 'link', () => setStatus(item, 'inbox'));

  return el('li', { className: item.status === 'inbox' ? '' : 'done' },
    el('div', { className: 'top' },
      el('div', { className: 'title' }, item.title),
      STATUS_LABELS[item.status] ? el('span', { className: 'status' }, STATUS_LABELS[item.status]) : null,
      el('span', { className: `kind ${item.kind}` }, KIND_LABELS[item.kind] || item.kind)),
    item.body ? el('div', { className: 'body' }, item.body) : null,
    el('div', { className: 'meta' },
      el('span', {}, item.postedOn ? `${time} · posted ${item.postedOn}` : time),
      item.url ? el('a', { href: item.url, target: '_blank', rel: 'noopener' }, item.source || 'Open') : null,
      actions,
      button('Delete', 'del', () => remove(item))));
}

function render() {
  const counts = Object.fromEntries(Object.entries(FILTERS).map(([key, test]) => [key, items.filter(test).length]));
  document.querySelectorAll('.tabs button').forEach((tab) => {
    tab.classList.toggle('active', tab.dataset.filter === filter);
    tab.querySelector('.n').textContent = counts[tab.dataset.filter];
  });

  const list = $('list');
  list.replaceChildren();
  const shown = items.filter(FILTERS[filter]);
  if (!shown.length) {
    list.append(el('p', { className: 'empty' }, filter === 'inbox' ? 'Nothing waiting in the queue.' : 'Nothing here yet.'));
    return;
  }

  // Newest first, grouped by the day each item was saved.
  let currentDay = null;
  let group = null;
  for (const item of shown) {
    const day = dayLabel(new Date(item.createdAt));
    if (day !== currentDay) {
      currentDay = day;
      list.append(el('h2', {}, day));
      group = el('ul');
      list.append(group);
    }
    group.append(card(item));
  }
}

async function load() {
  try {
    items = await api('/api/items?status=all');
    render();
  } catch (err) {
    showMessage(err.message, true);
  }
}

document.querySelectorAll('.tabs button').forEach((tab) => {
  tab.onclick = () => {
    filter = tab.dataset.filter;
    render();
  };
});

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

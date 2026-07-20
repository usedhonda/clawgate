const RECENT_LIMIT = 50;

const addForm = document.getElementById('add-form');
const addInput = document.getElementById('add-input');
const addError = document.getElementById('add-error');
const excludedList = document.getElementById('excluded-list');
const excludedEmpty = document.getElementById('excluded-empty');
const domainList = document.getElementById('domain-list');
const domainEmpty = document.getElementById('domain-empty');
const recentList = document.getElementById('recent-list');
const recentEmpty = document.getElementById('recent-empty');

const state = {
  excludedDomains: [],
  sendLog: [],
};

init().catch(() => undefined);

async function init() {
  const stored = await chrome.storage.local.get({ excludedDomains: [], passiveSendLog: [] });
  state.excludedDomains = normalizeDomainList(stored.excludedDomains);
  state.sendLog = Array.isArray(stored.passiveSendLog) ? stored.passiveSendLog : [];
  renderAll();

  addForm.addEventListener('submit', onAddSubmit);
  addInput.addEventListener('input', () => hideError());

  chrome.storage.onChanged.addListener((changes, areaName) => {
    if (areaName !== 'local') {
      return;
    }
    if (changes.excludedDomains) {
      state.excludedDomains = normalizeDomainList(changes.excludedDomains.newValue);
      renderExcluded();
      renderDomainSummary();
    }
    if (changes.passiveSendLog) {
      state.sendLog = Array.isArray(changes.passiveSendLog.newValue) ? changes.passiveSendLog.newValue : [];
      renderDomainSummary();
      renderRecent();
    }
  });
}

function renderAll() {
  renderExcluded();
  renderDomainSummary();
  renderRecent();
}

async function onAddSubmit(event) {
  event.preventDefault();
  const domain = normalizeDomainInput(addInput.value);
  if (!domain) {
    showError('有効なドメインを入力してください（例: example.com）');
    return;
  }
  hideError();
  addInput.value = '';
  await addExclusion(domain);
}

async function addExclusion(domain) {
  const stored = await chrome.storage.local.get({ excludedDomains: [] });
  const list = normalizeDomainList(stored.excludedDomains);
  if (!list.includes(domain)) {
    list.push(domain);
    await chrome.storage.local.set({ excludedDomains: list });
  }
}

async function removeExclusion(domain) {
  const stored = await chrome.storage.local.get({ excludedDomains: [] });
  const list = normalizeDomainList(stored.excludedDomains).filter((item) => item !== domain);
  await chrome.storage.local.set({ excludedDomains: list });
}

function renderExcluded() {
  excludedList.replaceChildren();
  const domains = state.excludedDomains;
  if (!domains.length) {
    excludedEmpty.hidden = false;
    return;
  }
  excludedEmpty.hidden = true;
  for (const domain of domains) {
    const li = document.createElement('li');
    li.className = 'chip';

    const name = document.createElement('span');
    name.className = 'chip-domain';
    name.textContent = domain;

    const remove = document.createElement('button');
    remove.type = 'button';
    remove.className = 'chip-remove';
    remove.textContent = '解除';
    remove.addEventListener('click', () => {
      removeExclusion(domain).catch(() => undefined);
    });

    li.append(name, remove);
    excludedList.append(li);
  }
}

function renderDomainSummary() {
  domainList.replaceChildren();
  const rows = aggregateByDomain(state.sendLog);
  if (!rows.length) {
    domainEmpty.hidden = false;
    return;
  }
  domainEmpty.hidden = true;
  for (const row of rows) {
    const excluded = isExcludedHostname(row.domain, state.excludedDomains);
    const li = document.createElement('li');
    li.className = excluded ? 'domain-row is-excluded' : 'domain-row';

    const name = document.createElement('span');
    name.className = 'domain-name';
    name.textContent = row.domain;

    const count = document.createElement('span');
    count.className = 'domain-count';
    count.textContent = `${row.count}件`;

    const time = document.createElement('span');
    time.className = 'domain-time';
    time.textContent = formatRelativeTime(row.lastSentAt);

    const action = document.createElement('span');
    action.className = 'domain-action';
    if (excluded) {
      const tag = document.createElement('span');
      tag.className = 'excluded-tag';
      tag.textContent = '除外済み';
      action.append(tag);
    } else {
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'ghost-button';
      button.textContent = 'このドメインを除外';
      button.addEventListener('click', () => {
        addExclusion(row.domain).catch(() => undefined);
      });
      action.append(button);
    }

    li.append(name, count, time, action);
    domainList.append(li);
  }
}

function renderRecent() {
  recentList.replaceChildren();
  const log = state.sendLog;
  if (!log.length) {
    recentEmpty.hidden = false;
    return;
  }
  recentEmpty.hidden = true;
  const recent = log.slice(Math.max(0, log.length - RECENT_LIMIT)).reverse();
  for (const entry of recent) {
    const li = document.createElement('li');
    li.className = 'recent-row';

    const time = document.createElement('span');
    time.className = 'recent-time';
    time.textContent = formatRelativeTime(Date.parse(entry?.sentAt));

    const domain = document.createElement('span');
    domain.className = 'recent-domain';
    domain.textContent = typeof entry?.domain === 'string' ? entry.domain : '';

    const title = document.createElement('span');
    title.className = 'recent-title';
    title.textContent = typeof entry?.title === 'string' && entry.title ? entry.title : (typeof entry?.url === 'string' ? entry.url : '');

    li.append(time, domain, title);

    if (entry?.manual) {
      const badge = document.createElement('span');
      badge.className = 'manual-badge';
      badge.textContent = '手動';
      li.append(badge);
    }

    recentList.append(li);
  }
}

function aggregateByDomain(log) {
  const map = new Map();
  for (const entry of log) {
    const domain = typeof entry?.domain === 'string' ? entry.domain : '';
    if (!domain) {
      continue;
    }
    const existing = map.get(domain) || { domain, count: 0, lastSentAt: 0 };
    existing.count += 1;
    const t = Date.parse(entry?.sentAt);
    if (Number.isFinite(t) && t > existing.lastSentAt) {
      existing.lastSentAt = t;
    }
    map.set(domain, existing);
  }
  return Array.from(map.values()).sort((a, b) => b.count - a.count || b.lastSentAt - a.lastSentAt);
}

function normalizeDomainList(value) {
  if (!Array.isArray(value)) {
    return [];
  }
  const seen = new Set();
  for (const item of value) {
    if (typeof item !== 'string') {
      continue;
    }
    const domain = item.trim().toLowerCase();
    if (domain) {
      seen.add(domain);
    }
  }
  return Array.from(seen);
}

function normalizeDomainInput(raw) {
  let value = (raw || '').trim();
  if (!value) {
    return null;
  }
  if (/^[a-z][a-z0-9+.-]*:\/\//i.test(value)) {
    try {
      value = new URL(value).hostname;
    } catch {
      return null;
    }
  } else {
    value = value.split('/')[0];
  }
  value = value.replace(/^[^@]*@/, '');
  value = value.split(':')[0];
  value = value.trim().toLowerCase();
  if (!value || !/^[a-z0-9.-]+$/.test(value)) {
    return null;
  }
  if (value.startsWith('.') || value.endsWith('.') || value.startsWith('-') || value.endsWith('-')) {
    return null;
  }
  if (!value.includes('.')) {
    return null;
  }
  return value;
}

function hostnameMatchesDomain(hostname, domain) {
  const host = (hostname || '').toLowerCase();
  const target = (domain || '').toLowerCase();
  if (!host || !target) {
    return false;
  }
  return host === target || host.endsWith(`.${target}`);
}

function isExcludedHostname(hostname, excludedDomains) {
  if (!Array.isArray(excludedDomains) || !excludedDomains.length) {
    return false;
  }
  return excludedDomains.some((domain) => hostnameMatchesDomain(hostname, domain));
}

function formatRelativeTime(input) {
  const t = typeof input === 'number' ? input : Date.parse(input);
  if (!Number.isFinite(t) || t <= 0) {
    return '';
  }
  const diff = Date.now() - t;
  if (diff < 60 * 1000) {
    return 'たった今';
  }
  const min = Math.floor(diff / (60 * 1000));
  if (min < 60) {
    return `${min}分前`;
  }
  const hour = Math.floor(min / 60);
  if (hour < 24) {
    return `${hour}時間前`;
  }
  const day = Math.floor(hour / 24);
  if (day < 30) {
    return `${day}日前`;
  }
  const month = Math.floor(day / 30);
  if (month < 12) {
    return `${month}ヶ月前`;
  }
  return `${Math.floor(month / 12)}年前`;
}

function showError(message) {
  addError.textContent = message;
  addError.hidden = false;
}

function hideError() {
  addError.hidden = true;
  addError.textContent = '';
}

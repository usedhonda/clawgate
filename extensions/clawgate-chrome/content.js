const MAX_CONTENT_LENGTH = 5000;
const MAX_OCR_TEXT_LENGTH = 800;
const MAX_CAPTION_LENGTH = 280;
const OCR_UNAVAILABLE_REASON = 'client_ocr_unavailable';
const CONTENT_DIAGNOSTIC_VERSION = '0.4.1+ondemand-1';
const CONTENT_DIAGNOSTIC_ATTR = 'data-clawgate-content-version';
const CONTENT_DIAGNOSTIC_TIME_ATTR = 'data-clawgate-content-loaded-at';
const CONTENT_DIAGNOSTIC_INSTANCE_ATTR = 'data-clawgate-content-instance';
const ROOT_SELECTORS = ['article', 'main', '[role="main"]'];
const REMOVE_SELECTORS = [
  'script',
  'style',
  'noscript',
  'nav',
  'header',
  'footer',
  'aside',
  'form',
  'dialog',
  'svg',
  'canvas',
  'video',
  'audio',
  'iframe',
  '[aria-hidden="true"]',
  '[hidden]',
  '[style*="display:none"]',
  '[style*="display: none"]',
  '[style*="visibility:hidden"]',
  '[style*="visibility: hidden"]',
  '[style*="opacity:0"]',
  '[style*="opacity: 0"]',
  '[style*="font-size:0"]',
  '[style*="font-size: 0"]',
  '[style*="height:0"]',
  '[style*="height: 0"]',
  '[style*="width:0"]',
  '[style*="width: 0"]',
  '[style*="overflow:hidden"][style*="height:1px"]',
].join(',');

const INVISIBLE_CHARS = /[\u200B\u200C\u200D\u200E\u200F\u2060\u2061\u2062\u2063\u2064\uFEFF\u00AD\u034F\u061C\u115F\u1160\u17B4\u17B5\u180E\u2000-\u200A\u202A-\u202E\u2066-\u2069\uFFA0\uFFF9-\uFFFB]/g;

const INJECTION_PATTERNS = [
  /\[system\]/gi,
  /\[instruction\]/gi,
  /\[INST\]/gi,
  /<<SYS>>/gi,
  /<\/SYS>/gi,
  /ignore\s+(all\s+)?previous\s+instructions?/gi,
  /ignore\s+(all\s+)?above\s+instructions?/gi,
  /disregard\s+(all\s+)?previous/gi,
  /you\s+are\s+now\s+/gi,
  /act\s+as\s+(a\s+|an\s+)?/gi,
  /new\s+instructions?:/gi,
  /system\s*prompt:/gi,
  /\bdo\s+not\s+follow\s+(any\s+)?previous/gi,
  /override\s+(all\s+)?instructions/gi,
  /forget\s+(all\s+)?(previous\s+)?instructions/gi,
  /assistant\s+to=functions/gi,
  /to=functions\.exec/gi,
  /\bcode=json\b/gi,
  /\{"command"\s*:/gi,
  /\{"command"\s*:\s*"(python3?|bash|sh|node|ruby|perl)/gi,
  /\btoolCallId\b/g,
  /\btextSignature\b/g,
  /\bthinkingSignature\b/g,
  /\bpartialJson\b/g,
  /[\u0C80-\u0CFF]{3,}.*(?:assistant|function|exec|command)/gi,
  /[\u0530-\u058F]{3,}.*(?:assistant|function|exec|command)/gi,
  /[\u10A0-\u10FF]{3,}.*(?:assistant|function|exec|command)/gi,
];

function installContentDiagnosticMarker() {
  const root = document.documentElement;
  if (!root) {
    return;
  }

  const loadedAt = new Date().toISOString();
  const instanceId = `cg-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
  root.setAttribute(CONTENT_DIAGNOSTIC_ATTR, CONTENT_DIAGNOSTIC_VERSION);
  root.setAttribute(CONTENT_DIAGNOSTIC_TIME_ATTR, loadedAt);
  root.setAttribute(CONTENT_DIAGNOSTIC_INSTANCE_ATTR, instanceId);

  let meta = document.head?.querySelector('meta[name=\"clawgate-content-version\"]');
  if (!(meta instanceof HTMLMetaElement)) {
    meta = document.createElement('meta');
    meta.name = 'clawgate-content-version';
    if (document.head) {
      document.head.appendChild(meta);
    }
  }
  if (meta instanceof HTMLMetaElement) {
    meta.content = `${CONTENT_DIAGNOSTIC_VERSION}|${loadedAt}|${instanceId}`;
  }
}

installContentDiagnosticMarker();

function stripInjectionPatterns(text) {
  let result = text;
  for (const pattern of INJECTION_PATTERNS) {
    result = result.replace(pattern, '[FILTERED]');
  }
  return result;
}

function normalizeText(text) {
  let normalized = (text || '').replace(INVISIBLE_CHARS, '').replace(/\s+/g, ' ').trim();
  normalized = stripInjectionPatterns(normalized);
  return normalized;
}

function pickRootNode() {
  for (const selector of ROOT_SELECTORS) {
    const candidate = document.querySelector(selector);
    if (candidate && normalizeText(candidate.innerText).length > 0) {
      return candidate;
    }
  }
  return document.body || document.documentElement;
}

function extractMeta(name, attribute = 'name') {
  const selector = `meta[${attribute}="${name}"]`;
  const element = document.querySelector(selector);
  return element?.content?.trim() || '';
}

function computeContentMetrics(rootClone) {
  const allText = normalizeText(rootClone.innerText || '');
  const allLinks = rootClone.querySelectorAll('a');
  let linkTextLen = 0;
  for (const a of allLinks) {
    linkTextLen += (a.innerText || '').length;
  }
  const linkDensity = allText.length > 0 ? linkTextLen / allText.length : 0;

  const paragraphs = rootClone.querySelectorAll('p');
  const paraLengths = [];
  for (const p of paragraphs) {
    const len = normalizeText(p.innerText || '').length;
    if (len > 10) {
      paraLengths.push(len);
    }
  }

  const avgParagraphLength = paraLengths.length > 0
    ? Math.round(paraLengths.reduce((a, b) => a + b, 0) / paraLengths.length)
    : 0;

  return {
    paragraphCount: paraLengths.length,
    avgParagraphLength,
    linkDensity: Math.round(linkDensity * 100) / 100,
    hasArticleTag: Boolean(document.querySelector('article')),
  };
}

function detectInjectionAttempt(rawText) {
  for (const pattern of INJECTION_PATTERNS) {
    pattern.lastIndex = 0;
    if (pattern.test(rawText)) {
      return true;
    }
  }
  const invisibleCount = (rawText.match(INVISIBLE_CHARS) || []).length;
  return invisibleCount > 20;
}

function isXPage() {
  return /(^|\.)x\.com$|(^|\.)twitter\.com$/i.test(window.location.hostname);
}

const MESSENGER_MAX_MESSAGES = 30;
const MESSENGER_MAX_MESSAGE_CHARS = 500;
const MESSENGER_MAX_BLOCK_CHARS = 4000;
const MESSENGER_LABEL_PATTERN = /^(.+?)[、,]\s*(.+?)[:：]\s*([\s\S]+)$/;
const MESSENGER_SELF_SENDER_PATTERN = /^(あなた|you)$/i;
// Messenger renders three different absolute-time shapes in the same aria-label
// slot (all verified on the live site 2026-08-19):
//   older than ~a week   "2024年3月11日 19:32"
//   within ~a week       "2026年8月14日(金) 11:02"   <- weekday in parentheses
//   today                "18:51"                    <- time only, no date
// Only the first shape used to parse, so today's messages — the ones a reminder
// is actually about — all fell back to the capture-time placeholder.
const MESSENGER_JP_DATETIME_PATTERN = /(\d{4})年\s*(\d{1,2})月\s*(\d{1,2})日\s*(?:[(（][^)）]{1,3}[)）])?\s*(\d{1,2}):(\d{2})/;
const MESSENGER_JP_TIME_ONLY_PATTERN = /^\s*(\d{1,2}):(\d{2})\s*$/;
const MESSENGER_YEAR_PATTERN = /(\d{4})年/;
// Facebook stamps the E2EE system notice with the Unix epoch ("1970年1月1日
// 7:30"). Anything below Facebook's own founding year is a placeholder, not an
// observation, so it must not reach the store.
const MESSENGER_MIN_PLAUSIBLE_YEAR = 2004;
const MESSENGER_THREAD_ID_PATTERN = /\/(?:e2ee\/)?t\/(\d+)/;
// Thread-state shapes, all verified against the live site 2026-08-19. The
// reaction label stops at "リアクションした人をチェックしよう", so it never
// names who reacted — a consumer may only say a reaction exists.
const MESSENGER_REACTION_PATTERN = /^絵文字付きのリアクションが(\d+)件ありました[:：]\s*([^。]+)。/;
const MESSENGER_READ_RECEIPT_PATTERN = /^(.+?)さんが(.+?)に閲覧$/;
const MESSENGER_REPLY_HEADING_PATTERN = /^(.+?)さんが(.+?)さんに返信しました$/;
const MESSENGER_ATTACHMENT_PATTERN = /^添付を開く[:：]\s*(.+)$/;
const MESSENGER_PHOTO_ALT_PATTERN = /^写真.*を開く$/;
const MESSENGER_COMPOSER_PATTERN = /^(.+)に書く$/;
const MESSENGER_UNREAD_PATTERN = /^未読/;
const MESSENGER_GROUP_LABEL_PATTERN = /^グループチャット[:：]/;
const MESSENGER_OPTIONS_LABEL_PATTERN = /^(.+?)さんのその他のオプション$/;
const MESSENGER_ONLINE_TEXT = 'オンライン中';
const MESSENGER_THREAD_LABEL_PREFIX = /^スレッド[:：]\s*/;
const MESSENGER_THREAD_LABEL_SUFFIX = /というタイトルのスレッド$/;
const MESSENGER_MAX_READERS = 20;
const MESSENGER_MAX_ATTACHMENTS = 5;
const MESSENGER_MAX_THREAD_ROWS = 50;
const MESSENGER_MAX_PREVIEW_CHARS = 300;

function isMessengerPage() {
  const location = window.location;
  if (!location) {
    return false;
  }
  const { hostname, pathname } = location;
  if (/(^|\.)messenger\.com$/i.test(hostname || '')) {
    return true;
  }
  if (/(^|\.)facebook\.com$/i.test(hostname || '') && (pathname || '').startsWith('/messages')) {
    return true;
  }
  return false;
}

function findMessengerLogContainer() {
  return document.querySelector('[role="main"] [role="log"]') || document.querySelector('[role="log"]');
}

function extractMessengerThreadId() {
  const match = MESSENGER_THREAD_ID_PATTERN.exec(window.location.pathname);
  return match ? match[1] : '';
}

function extractMessengerContactName() {
  // The thread header is a native heading element (observed as <h2> on the
  // live site) without an explicit role="heading" attribute — match h1-h3 and
  // the explicit role as a fallback for markup changes.
  const headings = Array.from(document.querySelectorAll(
    '[role="main"] h1, [role="main"] h2, [role="main"] h3, [role="main"] [role="heading"]'
  )).map((el) => normalizeText(el.textContent || '')).filter(Boolean);
  if (!headings.length) {
    return '';
  }
  // That first heading is a screen-reader landmark, so it carries a decorated
  // title — "スレッド: 山田 花子", "旅行の相談というタイトルのスレッド" — and
  // storing it verbatim files the contact under Messenger's label rather than
  // under their name. The undecorated name follows as a shorter heading
  // contained within the landmark (verified on four threads, 2026-08-19).
  const [landmark, ...rest] = headings;
  const plain = rest.find((text) => text.length < landmark.length && landmark.includes(text));
  if (plain) {
    return plain.slice(0, 200);
  }
  // A capture can land before the plain heading has rendered — Messenger
  // threads capture immediately, with no dwell — so strip the decoration the
  // landmark is known to carry rather than filing the contact under it.
  return landmark
    .replace(MESSENGER_THREAD_LABEL_PREFIX, '')
    .replace(MESSENGER_THREAD_LABEL_SUFFIX, '')
    .trim()
    .slice(0, 200);
}

function findMessageLabelElement(article) {
  if (article.hasAttribute('aria-label') && MESSENGER_LABEL_PATTERN.test(article.getAttribute('aria-label') || '')) {
    return article;
  }
  const candidates = article.querySelectorAll('[aria-label]');
  for (const el of candidates) {
    if (el.tagName === 'BUTTON' || el.closest('button, [role="toolbar"]')) {
      continue;
    }
    const label = el.getAttribute('aria-label') || '';
    if (MESSENGER_LABEL_PATTERN.test(label)) {
      return el;
    }
  }
  return null;
}

// Parses a locale-formatted absolute datetime out of the article's aria-label
// (e.g. "2024年7月25日 16:59"). Returns null if the format doesn't match —
// callers must treat the timestamp as approximate (capture time) in that case,
// never guess. Interpreted in the browser's local timezone, since Messenger
// renders times in the viewer's locale.
function parseMessengerTimestamp(raw) {
  const text = raw || '';
  const match = MESSENGER_JP_DATETIME_PATTERN.exec(text);
  if (match) {
    const [, year, month, day, hour, minute] = match.map(Number);
    const date = new Date(year, month - 1, day, hour, minute, 0, 0);
    return Number.isNaN(date.getTime()) ? null : { date, precision: 'exact' };
  }
  // A bare "H:MM" is only ever rendered for today — once a message crosses
  // midnight Messenger re-labels it with a date. Resolving it against the
  // capture date therefore yields a real wall-clock time rather than a guess,
  // and it makes the id of a given message converge: the same message captured
  // again tomorrow parses to the identical instant instead of becoming a
  // second row. The date is reconstructed rather than read, so it reports as
  // "inferred_date" — the store keeps that distinction instead of letting a
  // reconstructed date pass as one Messenger actually stated.
  const timeOnly = MESSENGER_JP_TIME_ONLY_PATTERN.exec(text);
  if (timeOnly) {
    const [, hour, minute] = timeOnly.map(Number);
    const now = new Date();
    const date = new Date(now.getFullYear(), now.getMonth(), now.getDate(), hour, minute, 0, 0);
    if (Number.isNaN(date.getTime())) {
      return null;
    }
    // Clock skew, or a tab left open across midnight, could put the resolved
    // time in the future. Roll back a day rather than claim a message that has
    // not happened yet.
    if (date.getTime() > now.getTime() + 60000) {
      date.setDate(date.getDate() - 1);
    }
    return { date, precision: 'inferred_date' };
  }
  return null;
}

function hasImplausibleYear(raw) {
  const match = MESSENGER_YEAR_PATTERN.exec(raw || '');
  return Boolean(match) && Number(match[1]) < MESSENGER_MIN_PLAUSIBLE_YEAR;
}

function parseMessengerArticle(article) {
  const labelEl = findMessageLabelElement(article);
  if (!labelEl) {
    return null;
  }
  const label = labelEl.getAttribute('aria-label') || '';
  const match = MESSENGER_LABEL_PATTERN.exec(label);
  if (!match) {
    return null;
  }
  const [, rawDateTime, rawSender, rawText] = match;
  // An epoch-stamped row is Facebook's E2EE system notice, not a message.
  // Dropping it keeps a fabricated 1970 timestamp out of a store that never
  // prunes.
  if (hasImplausibleYear(rawDateTime)) {
    return null;
  }
  const senderNormalized = normalizeText(rawSender);
  const fromSelf = MESSENGER_SELF_SENDER_PATTERN.test(senderNormalized);
  const sender = fromSelf ? 'Me' : senderNormalized;
  const text = normalizeText(rawText).slice(0, MESSENGER_MAX_MESSAGE_CHARS);
  if (!text) {
    return null;
  }
  const parsed = parseMessengerTimestamp(rawDateTime);
  // ISO-8601 always carries an explicit offset (toISOString() uses "Z"/UTC),
  // so downstream never has to guess which timezone this was written in.
  const sentAt = (parsed ? parsed.date : new Date()).toISOString();
  const sentAtPrecision = parsed ? parsed.precision : 'approximate';
  return {
    sender,
    fromSelf,
    text,
    sentAt,
    sentAtPrecision,
    reactions: extractMessengerReactions(article),
    readBy: extractMessengerReadBy(article),
    replyToName: extractMessengerReplyToName(article),
    attachments: extractMessengerAttachments(article),
  };
}

// Every signal below was verified to live inside the message's own
// [role="article"] element (reactions 2/2, read receipts 2/2 and 5/5, reply
// headings 3/3, attachments 6/6 across two threads), so a per-message scope is
// the real structure rather than an assumption about it.

function extractMessengerReactions(article) {
  for (const el of article.querySelectorAll('[aria-label]')) {
    const match = MESSENGER_REACTION_PATTERN.exec(el.getAttribute('aria-label') || '');
    if (!match) {
      continue;
    }
    const count = Number(match[1]);
    if (!Number.isFinite(count)) {
      return null;
    }
    // Messenger collapses the list to at most two distinct emoji.
    const emoji = match[2].split(/[、,]/).map((part) => part.trim()).filter(Boolean);
    return { count, emoji };
  }
  return null;
}

function extractMessengerReadBy(article) {
  const readers = [];
  for (const img of article.querySelectorAll('img[alt]')) {
    const match = MESSENGER_READ_RECEIPT_PATTERN.exec(normalizeText(img.alt || ''));
    if (!match) {
      continue;
    }
    const [, rawReader, rawTime] = match;
    if (hasImplausibleYear(rawTime)) {
      continue;
    }
    const parsed = parseMessengerTimestamp(rawTime);
    // Who read it is worth keeping even when the label's time does not parse,
    // but the capture time is not a read time: report null rather than a
    // placeholder that would read as "just now".
    readers.push({
      reader: normalizeText(rawReader).slice(0, 100),
      readAt: parsed ? parsed.date.toISOString() : null,
      readAtPrecision: parsed ? parsed.precision : 'approximate',
    });
    if (readers.length >= MESSENGER_MAX_READERS) {
      break;
    }
  }
  return readers;
}

function extractMessengerReplyToName(article) {
  for (const heading of article.querySelectorAll('h1, h2, h3, [role="heading"]')) {
    const match = MESSENGER_REPLY_HEADING_PATTERN.exec(normalizeText(heading.textContent || ''));
    if (match) {
      return normalizeText(match[2]).slice(0, 100);
    }
  }
  return '';
}

function extractMessengerAttachments(article) {
  const attachments = [];
  for (const el of article.querySelectorAll('[aria-label]')) {
    const match = MESSENGER_ATTACHMENT_PATTERN.exec(el.getAttribute('aria-label') || '');
    if (!match) {
      continue;
    }
    // Title and domain are concatenated with no delimiter ("...| Noteswww.
    // example.com"), so the label is passed through whole. Splitting it would be
    // a guess, and Messenger's own labelling is buggy enough to produce
    // "写真NaNを開く".
    attachments.push({ kind: 'link', label: normalizeText(match[1]).slice(0, 300) });
    if (attachments.length >= MESSENGER_MAX_ATTACHMENTS) {
      return attachments;
    }
  }
  for (const img of article.querySelectorAll('img[alt]')) {
    if (!MESSENGER_PHOTO_ALT_PATTERN.test(normalizeText(img.alt || ''))) {
      continue;
    }
    attachments.push({ kind: 'photo', label: normalizeText(img.alt || '').slice(0, 300) });
    if (attachments.length >= MESSENGER_MAX_ATTACHMENTS) {
      break;
    }
  }
  return attachments;
}

// The composer names every participant in full, while the thread title may be
// an abbreviation ("涛、桂太" against "程 涛、豊野 桂太"), so this is the
// accurate list for identifying who a thread is actually with.
function extractMessengerParticipants() {
  for (const el of document.querySelectorAll('[role="main"] [aria-label]')) {
    const match = MESSENGER_COMPOSER_PATTERN.exec(el.getAttribute('aria-label') || '');
    if (match) {
      return normalizeText(match[1]).slice(0, 300);
    }
  }
  return '';
}

function messengerRowTexts(row) {
  const texts = [];
  for (const node of row.querySelectorAll('*')) {
    for (const child of node.childNodes) {
      if (child.nodeType === 3) {
        const text = normalizeText(child.textContent || '');
        if (text) {
          texts.push(text);
        }
      }
    }
  }
  return texts;
}

// The sidebar is virtualised — about 21 rows against a much longer account —
// so this is a window on the same terms as the message log, and a thread
// missing from it was not observed rather than absent.
function extractMessengerThreadList() {
  const rows = Array.from(document.querySelectorAll('[role="grid"] [role="row"]')).slice(0, MESSENGER_MAX_THREAD_ROWS);
  const list = [];
  for (const row of rows) {
    const links = Array.from(row.querySelectorAll('a[href]'));
    const threadLink = links.find((a) => MESSENGER_THREAD_ID_PATTERN.test(a.getAttribute('href') || ''));
    if (!threadLink) {
      continue;
    }
    const threadId = MESSENGER_THREAD_ID_PATTERN.exec(threadLink.getAttribute('href'))[1];
    const optionsLabel = Array.from(row.querySelectorAll('[aria-label]'))
      .map((el) => el.getAttribute('aria-label') || '')
      .map((label) => MESSENGER_OPTIONS_LABEL_PATTERN.exec(label))
      .find(Boolean);
    const isGroup = links.some((a) => MESSENGER_GROUP_LABEL_PATTERN.test(a.getAttribute('aria-label') || ''));
    const abbr = row.querySelector('abbr[aria-label]');
    const texts = messengerRowTexts(row);
    // An online thread prepends "オンライン中", which shifts every later text
    // node — 7 of 21 rows on the measured account. Drop it before reading by
    // position or the presence lands in the name field.
    const body = texts.filter((text) => text !== MESSENGER_ONLINE_TEXT);
    const unread = body.some((text) => MESSENGER_UNREAD_PATTERN.test(text));
    const preview = body.filter((text) => !MESSENGER_UNREAD_PATTERN.test(text)).slice(1, -2).join(' ');
    list.push({
      threadId,
      name: optionsLabel ? normalizeText(optionsLabel[1]).slice(0, 200) : (body[0] || ''),
      isGroup,
      unread,
      previewText: preview.slice(0, MESSENGER_MAX_PREVIEW_CHARS),
      // Kept as the string Messenger rendered. The sidebar carries no absolute
      // time anywhere, so converting this to an instant would manufacture a
      // precision the DOM never had.
      lastActivityLabel: abbr ? normalizeText(abbr.getAttribute('aria-label') || '') : '',
    });
  }

  const folders = [];
  for (const el of document.querySelectorAll('[role="navigation"] [aria-label], [role="tablist"] [aria-label]')) {
    const label = normalizeText(el.getAttribute('aria-label') || '');
    const match = /^(.+?)\s*·\s*未読(\d+)件$/.exec(label);
    if (match) {
      folders.push({ name: normalizeText(match[1]).slice(0, 100), unreadCount: Number(match[2]) });
    }
  }

  if (!list.length && !folders.length) {
    return null;
  }
  return { capturedAt: new Date().toISOString(), captureScope: 'visible_window', rows: list, folders };
}

function hashString(value) {
  let hash = 0;
  for (let i = 0; i < value.length; i += 1) {
    hash = (hash * 31 + value.charCodeAt(i)) | 0;
  }
  return (hash >>> 0).toString(36);
}

function computeMessengerSignature(messages) {
  const last = messages[messages.length - 1];
  const raw = `${messages.length}:${last ? `${last.sender}|${last.text.slice(0, 80)}` : ''}`;
  return `${messages.length}-${hashString(raw)}`;
}

// A deterministic per-message id so the receiving store can dedupe on
// re-capture instead of relying solely on the thread-level contentSignature.
// Stable for "exact". Stable for "inferred_date" only while the inferred date
// is right: a tab left open across midnight resolves yesterday's "10:00"
// against today, and that row never merges with the correctly dated one — they
// are different instants, not two spellings of one. It is NOT stable for
// "approximate": that sentAt is a capture-time placeholder (see
// parseMessengerArticle) and changes on every re-capture. There is no
// DOM-native message id to fall back on (verified: Facebook's message rows
// carry no unique id/data- attribute).
function computeMessengerMessageId(threadId, message) {
  const raw = `${threadId}|${message.sentAt}|${message.fromSelf}|${message.text.slice(0, 200)}`;
  return `msg:${threadId}:${hashString(raw)}`;
}

// Returns the richer structured capture oc-general.cc's contract needs
// (messages array with sender/timestamp, plus coverage metadata) alongside a
// human-readable `content` block for the fallback/local-debug path. DOM
// extraction only ever sees what's currently rendered, so captureScope is
// always "visible_window" — never claim "full_thread" from a DOM scrape.
function extractMessengerConversation() {
  const container = findMessengerLogContainer();
  if (!container) {
    return null;
  }
  const threadId = extractMessengerThreadId();

  // Facebook renders each message bubble as `<div role="article">`, not an
  // `<article>` tag (verified against the live site 2026-08-09) — match both
  // in case a future markup revision uses the real element.
  const articles = Array.from(container.querySelectorAll('article, [role="article"]')).slice(-MESSENGER_MAX_MESSAGES);
  const messages = [];
  for (const article of articles) {
    const parsed = parseMessengerArticle(article);
    if (parsed) {
      messages.push(parsed);
    }
  }
  if (!messages.length) {
    return null;
  }

  let injectionDetected = false;
  const lines = [];
  const includedMessages = [];
  let totalChars = 0;
  for (const message of messages) {
    if (detectInjectionAttempt(message.text) || detectInjectionAttempt(message.sender)) {
      injectionDetected = true;
    }
    const line = `${message.sender}: ${message.text}`;
    if (totalChars + line.length > MESSENGER_MAX_BLOCK_CHARS) {
      break;
    }
    lines.push(line);
    includedMessages.push(message);
    totalChars += line.length;
  }
  if (!lines.length) {
    return null;
  }

  return {
    content: `## Messenger Conversation\n${lines.join('\n')}`,
    contentSignature: computeMessengerSignature(messages),
    injectionDetected,
    threadId,
    contactName: extractMessengerContactName(),
    captureScope: 'visible_window',
    messageCount: includedMessages.length,
    oldestCapturedAt: includedMessages[0].sentAt,
    messages: includedMessages.map((message) => ({
      id: computeMessengerMessageId(threadId, message),
      sender: message.sender,
      fromSelf: message.fromSelf,
      text: message.text,
      sentAt: message.sentAt,
      sentAtPrecision: message.sentAtPrecision,
      reactions: message.reactions,
      readBy: message.readBy,
      replyToName: message.replyToName,
      attachments: message.attachments,
    })),
    participants: extractMessengerParticipants(),
    threadList: extractMessengerThreadList(),
  };
}

function isLikelyDecorativeImage(image) {
  const src = image.currentSrc || image.src || '';
  const alt = (image.alt || '').toLowerCase();
  return src.includes('/profile_images/')
    || src.includes('/emoji/')
    || src.includes('/abs-0.twimg.com/emoji/')
    || alt.includes('avatar')
    || alt === 'emoji';
}

function isVisibleRect(rect) {
  return rect.width >= 80
    && rect.height >= 80
    && rect.bottom > 0
    && rect.right > 0
    && rect.top < window.innerHeight
    && rect.left < window.innerWidth;
}

function getNodeTextSnippet(node, maxLength) {
  return normalizeText(node?.innerText || '').slice(0, maxLength);
}

function collectImageCandidates(root) {
  const scope = root || document.body || document.documentElement;
  const images = Array.from(scope.querySelectorAll('img'));
  const candidates = [];

  for (const image of images) {
    const src = image.currentSrc || image.src || '';
    if (!src || !/^https?:/i.test(src) || isLikelyDecorativeImage(image)) {
      continue;
    }

    const rect = image.getBoundingClientRect();
    if (!isVisibleRect(rect)) {
      continue;
    }

    const naturalWidth = image.naturalWidth || Math.round(rect.width);
    const naturalHeight = image.naturalHeight || Math.round(rect.height);
    if (naturalWidth < 180 || naturalHeight < 180) {
      continue;
    }

    let score = rect.width * rect.height;
    const article = image.closest('article');
    const figure = image.closest('figure');
    const captionSource = figure || article || image.parentElement || scope;
    const captionText = getNodeTextSnippet(captionSource, MAX_CAPTION_LENGTH);

    if (isXPage()) {
      if (src.includes('pbs.twimg.com/media')) {
        score += 200000;
      }
      if (article) {
        score += 80000;
      }
    } else {
      if (scope.contains(image)) {
        score += 25000;
      }
      if (figure) {
        score += 10000;
      }
    }

    candidates.push({
      image,
      src,
      altText: normalizeText(image.alt || '').slice(0, 200),
      captionText,
      rect,
      naturalWidth,
      naturalHeight,
      score,
    });
  }

  candidates.sort((a, b) => b.score - a.score);
  return candidates;
}

function pickPrimaryImageCandidate(root, preferredImageURL = '') {
  const candidates = collectImageCandidates(root);
  if (preferredImageURL) {
    const matched = candidates.find((candidate) => candidate.src === preferredImageURL);
    if (matched) {
      return matched;
    }
  }
  return candidates[0] || null;
}

const EXTENSION_CONTEXT_INVALIDATED_REASON = 'extension_context_invalidated';
const IMAGE_FETCH_PORT_NAME = 'clawgate_image_fetch';
const activeImageFetchPorts = new Set();

function disconnectImageFetchPort(port) {
  if (!port) return;
  activeImageFetchPorts.delete(port);
  try { port.disconnect(); } catch {}
}

function disconnectActiveImageFetchPorts() {
  for (const port of Array.from(activeImageFetchPorts)) {
    disconnectImageFetchPort(port);
  }
}

window.addEventListener('pagehide', disconnectActiveImageFetchPorts);

function requestImageDataURL(url) {
  return new Promise((resolve, reject) => {
    const runtime = getRuntimeOrInvalidate('connect');
    if (!runtime) {
      reject(makeInvalidationError());
      return;
    }

    let port = null;
    let settled = false;
    const finishResolve = (value) => {
      if (settled) return;
      settled = true;
      disconnectImageFetchPort(port);
      resolve(value);
    };
    const finishReject = (error) => {
      if (settled) return;
      settled = true;
      disconnectImageFetchPort(port);
      reject(error);
    };

    try {
      port = runtime.connect({ name: IMAGE_FETCH_PORT_NAME });
      activeImageFetchPorts.add(port);
    } catch (error) {
      finishReject(markExtensionContextInvalidated(error));
      return;
    }

    const handleMessage = (response) => {
      try {
        if (typeof response?.sandboxUrl === 'string' && response.sandboxUrl) {
          _cachedSandboxURL = response.sandboxUrl;
        }
        if (!response?.ok || !response?.dataUrl) {
          finishReject(new Error(response?.error || 'Image fetch failed'));
          return;
        }
        finishResolve(response.dataUrl);
      } catch (error) {
        finishReject(markExtensionContextInvalidated(error));
      }
    };

    const handleDisconnect = () => {
      activeImageFetchPorts.delete(port);
      const runtimeError = getLastRuntimeErrorOrInvalidate();
      if (runtimeError && isContextInvalidationError(runtimeError)) {
        finishReject(markExtensionContextInvalidated(runtimeError));
        return;
      }
      finishReject(runtimeError ? new Error(runtimeError.message) : makeInvalidationError());
    };

    try {
      port.onMessage.addListener(handleMessage);
      port.onDisconnect.addListener(handleDisconnect);
      port.postMessage({ type: 'fetch_image_data_url', url });
    } catch (error) {
      finishReject(markExtensionContextInvalidated(error));
    }
  });
}

let ocrSandboxFramePromise = null;
let ocrRequestSequence = 0;
const pendingOCRRequests = new Map();
let extensionContextInvalidated = false;
let windowMessageListenerAttached = false;
let windowErrorListenerAttached = false;
let ocrSandboxFrame = null;
let ocrSandboxFrameReady = false;
let _cachedSandboxURL = null;
const CONTENT_RUNTIME_HANDLER_KEY = '__clawgateContentRuntimeHandler';

function makeInvalidationError() {
  return new Error(EXTENSION_CONTEXT_INVALIDATED_REASON);
}

function isContextInvalidationError(error) {
  const message = error instanceof Error ? error.message : String(error || '');
  return /Extension context invalidated/i.test(message)
    || /Cannot read properties of undefined \(reading 'getURL'\)/i.test(message)
    || /Cannot read properties of undefined \(reading 'sendMessage'\)/i.test(message)
    || /Cannot read properties of undefined \(reading 'connect'\)/i.test(message)
    || /message port closed/i.test(message);
}

function rejectPendingOCRRequests(error) {
  for (const [requestId, pending] of pendingOCRRequests.entries()) {
    pendingOCRRequests.delete(requestId);
    pending.reject(error);
  }
}

function teardownExtensionBindings() {
  disconnectActiveImageFetchPorts();

  if (windowMessageListenerAttached) {
    window.removeEventListener('message', handleSandboxMessage);
    windowMessageListenerAttached = false;
  }

  if (windowErrorListenerAttached) {
    window.removeEventListener('error', swallowContextInvalidation, true);
    window.removeEventListener('unhandledrejection', swallowContextInvalidation);
    windowErrorListenerAttached = false;
  }

  if (ocrSandboxFrame instanceof HTMLIFrameElement) {
    ocrSandboxFrame.remove();
  }
  ocrSandboxFrame = null;
  ocrSandboxFrameReady = false;
  ocrSandboxFramePromise = null;
}

function markExtensionContextInvalidated(error) {
  if (extensionContextInvalidated) {
    return makeInvalidationError();
  }

  extensionContextInvalidated = true;
  const invalidationError = isContextInvalidationError(error)
    ? (error instanceof Error ? error : makeInvalidationError())
    : makeInvalidationError();
  rejectPendingOCRRequests(invalidationError);
  teardownExtensionBindings();
  return invalidationError;
}

function swallowContextInvalidation(event) {
  const payload = event?.error ?? event?.reason ?? event?.message ?? null;
  if (!isContextInvalidationError(payload)) {
    return;
  }

  markExtensionContextInvalidated(payload instanceof Error ? payload : new Error(String(payload)));
  if (typeof event.preventDefault === 'function') {
    event.preventDefault();
  }
  if (typeof event.stopImmediatePropagation === 'function') {
    event.stopImmediatePropagation();
  }
}

function getRuntimeOrInvalidate(requiredMethod) {
  if (extensionContextInvalidated) {
    return null;
  }

  try {
    const runtime = globalThis.chrome?.runtime;
    if (!runtime || typeof runtime[requiredMethod] !== 'function') {
      markExtensionContextInvalidated(makeInvalidationError());
      return null;
    }
    return runtime;
  } catch (error) {
    markExtensionContextInvalidated(error);
    return null;
  }
}

function ensureOCRSessionBindings() {
  if (!windowErrorListenerAttached) {
    window.addEventListener('error', swallowContextInvalidation, true);
    window.addEventListener('unhandledrejection', swallowContextInvalidation);
    windowErrorListenerAttached = true;
  }

  if (!windowMessageListenerAttached) {
    window.addEventListener('message', handleSandboxMessage);
    windowMessageListenerAttached = true;
  }
}

function getRuntimeOnMessageOrInvalidate() {
  if (extensionContextInvalidated) {
    return null;
  }

  try {
    const onMessage = globalThis.chrome?.runtime?.onMessage;
    if (!onMessage || typeof onMessage.addListener !== 'function') {
      markExtensionContextInvalidated(makeInvalidationError());
      return null;
    }
    return onMessage;
  } catch (error) {
    markExtensionContextInvalidated(error);
    return null;
  }
}

function getLastRuntimeErrorOrInvalidate() {
  if (extensionContextInvalidated) {
    return makeInvalidationError();
  }

  try {
    return globalThis.chrome?.runtime?.lastError || null;
  } catch (error) {
    return markExtensionContextInvalidated(error);
  }
}

function isOwnedReadyOCRFrame(frame = ocrSandboxFrame) {
  return frame instanceof HTMLIFrameElement
    && frame === ocrSandboxFrame
    && ocrSandboxFrameReady
    && frame.isConnected
    && Boolean(frame.contentWindow);
}

function ensureOCRSandbox() {
  if (extensionContextInvalidated) {
    return Promise.reject(makeInvalidationError());
  }
  if (ocrSandboxFramePromise) {
    return ocrSandboxFramePromise;
  }

  ocrSandboxFramePromise = new Promise((resolve, reject) => {
    if (!_cachedSandboxURL) {
      reject(new Error(OCR_UNAVAILABLE_REASON));
      return;
    }

    const iframe = document.createElement('iframe');
    iframe.id = 'clawgate-ocr-sandbox';
    ocrSandboxFrame = iframe;
    ocrSandboxFrameReady = false;
    iframe.addEventListener('load', () => {
      if (ocrSandboxFrame === iframe && iframe.isConnected && iframe.contentWindow) {
        ocrSandboxFrameReady = true;
        resolve(iframe);
      } else {
        reject(new Error(OCR_UNAVAILABLE_REASON));
      }
    }, { once: true });
    iframe.addEventListener('error', () => reject(new Error(OCR_UNAVAILABLE_REASON)), { once: true });
    try {
      iframe.src = _cachedSandboxURL;
    } catch (error) {
      reject(markExtensionContextInvalidated(error));
      return;
    }
    iframe.style.display = 'none';
    iframe.setAttribute('aria-hidden', 'true');
    (document.documentElement || document.body).appendChild(iframe);
  });

  ocrSandboxFramePromise.catch((error) => {
    if (isContextInvalidationError(error)) {
      markExtensionContextInvalidated(error);
    }
  });

  return ocrSandboxFramePromise;
}

function handleSandboxMessage(event) {
  if (extensionContextInvalidated) {
    return;
  }

  if (!isOwnedReadyOCRFrame() || event.source !== ocrSandboxFrame.contentWindow) {
    return;
  }
  const data = event.data;
  if (!data
    || data.type !== 'clawgate_ocr_result'
    || typeof data.id !== 'string'
    || typeof data.ok !== 'boolean') {
    return;
  }

  const pending = pendingOCRRequests.get(data.id);
  if (!pending) {
    return;
  }
  pendingOCRRequests.delete(data.id);

  if (data.ok) {
    pending.resolve(typeof data.text === 'string' ? normalizeText(data.text).slice(0, MAX_OCR_TEXT_LENGTH) : '');
  } else {
    pending.reject(new Error(typeof data.error === 'string' ? data.error : OCR_UNAVAILABLE_REASON));
  }
}

async function runOCRSession(work) {
  ensureOCRSessionBindings();
  try {
    return await work();
  } finally {
    teardownExtensionBindings();
  }
}

async function extractOCRText(imageURL) {
  if (extensionContextInvalidated) {
    throw makeInvalidationError();
  }

  const dataUrl = await requestImageDataURL(imageURL);
  const iframe = await ensureOCRSandbox();
  const requestId = `ocr-${Date.now()}-${ocrRequestSequence += 1}`;

  return new Promise((resolve, reject) => {
    const timeout = window.setTimeout(() => {
      pendingOCRRequests.delete(requestId);
      reject(new Error('OCR timeout'));
    }, 10000);

    pendingOCRRequests.set(requestId, {
      resolve: (text) => {
        window.clearTimeout(timeout);
        resolve(text);
      },
      reject: (error) => {
        window.clearTimeout(timeout);
        reject(error);
      },
    });

    if (!isOwnedReadyOCRFrame(iframe)) {
      pendingOCRRequests.delete(requestId);
      window.clearTimeout(timeout);
      reject(extensionContextInvalidated ? makeInvalidationError() : new Error(OCR_UNAVAILABLE_REASON));
      return;
    }

    iframe.contentWindow.postMessage({
      type: 'clawgate_ocr_request',
      id: requestId,
      imageDataUrl: dataUrl,
    }, '*');
  });
}

function formatImageContext(imageContext) {
  if (!imageContext) {
    return '';
  }

  const sections = [];
  if (imageContext.altText) {
    sections.push(`Alt: ${imageContext.altText}`);
  }
  if (imageContext.ocrText) {
    sections.push(`Image text: ${imageContext.ocrText}`);
  }
  if (imageContext.captionText) {
    sections.push(`Nearby context: ${imageContext.captionText}`);
  }

  if (sections.length === 0) {
    return '';
  }

  return `## Image Context\n${sections.join('\n')}`;
}

async function extractImageContext(root, preferredImageURL = '') {
  const candidate = pickPrimaryImageCandidate(root, preferredImageURL);
  if (!candidate) {
    return null;
  }

  let ocrText = '';
  let error = '';
  try {
    ocrText = await runOCRSession(() => extractOCRText(candidate.src));
  } catch (ocrError) {
    error = ocrError instanceof Error ? ocrError.message : String(ocrError);
    if (isContextInvalidationError(ocrError)) {
      markExtensionContextInvalidated(ocrError);
    }
  }
  if (!ocrText && !error) {
    error = OCR_UNAVAILABLE_REASON;
  }

  const result = {
    source: 'client_ocr',
    imageURL: candidate.src,
    altText: candidate.altText,
    captionText: candidate.captionText,
    ocrText,
    ocrAvailable: true,
    width: candidate.naturalWidth,
    height: candidate.naturalHeight,
  };

  if (error) {
    result.error = error;
  }

  return result;
}

async function extractPagePayload(options = {}) {
  if (isMessengerPage()) {
    const messengerResult = extractMessengerConversation();
    if (messengerResult) {
      return {
        ok: true,
        url: window.location.href,
        title: normalizeText(document.title),
        content: messengerResult.content,
        contentMetrics: {
          isMessenger: true,
          messageCount: messengerResult.messageCount,
          injectionDetected: messengerResult.injectionDetected,
        },
        contentSignature: messengerResult.contentSignature,
        imageContext: null,
        meta: {
          description: extractMeta('description'),
          ogTitle: extractMeta('og:title', 'property'),
          ogImage: extractMeta('og:image', 'property'),
        },
        messenger: {
          threadId: messengerResult.threadId,
          contactName: messengerResult.contactName,
          captureScope: messengerResult.captureScope,
          messageCount: messengerResult.messageCount,
          oldestCapturedAt: messengerResult.oldestCapturedAt,
          contentSignature: messengerResult.contentSignature,
          messages: messengerResult.messages,
          participants: messengerResult.participants,
          threadList: messengerResult.threadList,
        },
      };
    }
    // Fall through to the generic extraction path below (empty/failed parse).
  }

  const root = pickRootNode();
  const clone = root.cloneNode(true);
  clone.querySelectorAll(REMOVE_SELECTORS).forEach((node) => node.remove());

  const rawText = clone.innerText || root.innerText || document.body?.innerText || '';
  const injectionDetected = detectInjectionAttempt(rawText);
  const baseContent = normalizeText(rawText).slice(0, MAX_CONTENT_LENGTH);
  const imageContext = await extractImageContext(root, options.preferredImageURL || '');
  const mergedContent = [baseContent, formatImageContext(imageContext)].filter(Boolean).join('\n\n');
  const metrics = computeContentMetrics(clone);
  if (injectionDetected) {
    metrics.injectionDetected = true;
  }
  if (imageContext) {
    metrics.hasPrimaryImage = true;
    metrics.primaryImageWidth = imageContext.width;
    metrics.primaryImageHeight = imageContext.height;
    metrics.hasImageOCR = Boolean(imageContext.ocrText);
  }

  return {
    ok: true,
    url: window.location.href,
    title: normalizeText(document.title),
    content: mergedContent,
    contentMetrics: metrics,
    imageContext,
    meta: {
      description: extractMeta('description'),
      ogTitle: extractMeta('og:title', 'property'),
      ogImage: extractMeta('og:image', 'property'),
    },
  };
}

function removeRuntimeMessageListener() {
  const currentHandler = globalThis[CONTENT_RUNTIME_HANDLER_KEY];
  if (!currentHandler) {
    return;
  }

  const runtimeOnMessage = getRuntimeOnMessageOrInvalidate();
  if (runtimeOnMessage && typeof runtimeOnMessage.removeListener === 'function') {
    try {
      runtimeOnMessage.removeListener(currentHandler);
    } catch (error) {
      markExtensionContextInvalidated(error);
    }
  }
  delete globalThis[CONTENT_RUNTIME_HANDLER_KEY];
}

function finalizeInjectedSession() {
  removeRuntimeMessageListener();
  teardownExtensionBindings();
}

function respondWithExtractionError(sendResponse, error) {
  sendResponse({
    ok: false,
    error: error instanceof Error ? error.message : String(error),
    url: window.location.href,
    title: normalizeText(document.title),
    content: '',
    contentMetrics: {},
    imageContext: null,
    meta: {},
  });
}

function handleRuntimeMessage(message, _sender, sendResponse) {
  if (message?.type === 'ping') {
    sendResponse({ ok: true });
    return false;
  }
  if (message?.type !== 'extract_content') {
    return undefined;
  }

  if (extensionContextInvalidated) {
    respondWithExtractionError(sendResponse, makeInvalidationError());
    finalizeInjectedSession();
    return false;
  }

  extractPagePayload({ preferredImageURL: typeof message.preferredImageURL === 'string' ? message.preferredImageURL : '' })
    .then((payload) => sendResponse(payload))
    .catch((error) => {
      respondWithExtractionError(sendResponse, error);
    })
    .finally(() => {
      teardownExtensionBindings();
    });

  return true;
}

removeRuntimeMessageListener();
const runtimeOnMessage = getRuntimeOnMessageOrInvalidate();
if (runtimeOnMessage && typeof runtimeOnMessage.addListener === 'function') {
  globalThis[CONTENT_RUNTIME_HANDLER_KEY] = handleRuntimeMessage;
  runtimeOnMessage.addListener(handleRuntimeMessage);
}

const MESSENGER_MUTATION_DEBOUNCE_MS = 2000;
const MESSENGER_OBSERVER_RETRY_MS = 2000;
let messengerObserver = null;
let messengerDebounceTimer = null;

function notifyMessengerContentChanged() {
  const runtime = getRuntimeOrInvalidate('sendMessage');
  if (!runtime) {
    return;
  }
  try {
    runtime.sendMessage({ type: 'messenger_content_changed' }, () => {
      void runtime.lastError;
    });
  } catch {}
}

function scheduleMessengerNotify() {
  if (messengerDebounceTimer) {
    clearTimeout(messengerDebounceTimer);
  }
  messengerDebounceTimer = setTimeout(() => {
    messengerDebounceTimer = null;
    notifyMessengerContentChanged();
  }, MESSENGER_MUTATION_DEBOUNCE_MS);
}

function setupMessengerObserver() {
  if (!isMessengerPage() || messengerObserver || extensionContextInvalidated) {
    return;
  }
  if (typeof MutationObserver === 'undefined') {
    return;
  }
  const container = findMessengerLogContainer();
  if (!container) {
    // The SPA may not have rendered the message log yet; retry shortly.
    setTimeout(setupMessengerObserver, MESSENGER_OBSERVER_RETRY_MS);
    return;
  }
  messengerObserver = new MutationObserver(() => {
    scheduleMessengerNotify();
  });
  messengerObserver.observe(container, { childList: true, subtree: true });
}

if (isMessengerPage()) {
  setupMessengerObserver();
}

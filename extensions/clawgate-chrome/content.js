const MAX_CONTENT_LENGTH = 5000;
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

function extractPagePayload() {
  const root = pickRootNode();
  const clone = root.cloneNode(true);
  clone.querySelectorAll(REMOVE_SELECTORS).forEach((node) => node.remove());

  const rawText = clone.innerText || root.innerText || document.body?.innerText || '';
  const injectionDetected = detectInjectionAttempt(rawText);
  const content = normalizeText(rawText).slice(0, MAX_CONTENT_LENGTH);
  const metrics = computeContentMetrics(clone);
  if (injectionDetected) {
    metrics.injectionDetected = true;
  }

  return {
    ok: true,
    url: window.location.href,
    title: normalizeText(document.title),
    content,
    contentMetrics: metrics,
    meta: {
      description: extractMeta('description'),
      ogTitle: extractMeta('og:title', 'property'),
      ogImage: extractMeta('og:image', 'property'),
    },
  };
}

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type !== 'extract_content') {
    return undefined;
  }

  try {
    sendResponse(extractPagePayload());
  } catch (error) {
    sendResponse({
      ok: false,
      error: error instanceof Error ? error.message : String(error),
      url: window.location.href,
      title: normalizeText(document.title),
      content: '',
      contentMetrics: {},
      meta: {},
    });
  }
  return true;
});

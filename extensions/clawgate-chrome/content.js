const MAX_CONTENT_LENGTH = 5000;
const MAX_OCR_TEXT_LENGTH = 800;
const MAX_CAPTION_LENGTH = 280;
const OCR_UNAVAILABLE_REASON = 'client_ocr_unavailable';
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

function isXPage() {
  return /(^|\.)x\.com$|(^|\.)twitter\.com$/i.test(window.location.hostname);
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

function requestImageDataURL(url) {
  return new Promise((resolve, reject) => {
    chrome.runtime.sendMessage({ type: 'fetch_image_data_url', url }, (response) => {
      const runtimeError = chrome.runtime.lastError;
      if (runtimeError) {
        reject(new Error(runtimeError.message));
        return;
      }
      if (!response?.ok || !response?.dataUrl) {
        reject(new Error(response?.error || 'Image fetch failed'));
        return;
      }
      resolve(response.dataUrl);
    });
  });
}

let ocrSandboxFramePromise = null;
let ocrRequestSequence = 0;
const pendingOCRRequests = new Map();

function getSandboxOrigin() {
  return new URL(chrome.runtime.getURL('sandbox/ocr.html')).origin;
}

function ensureOCRSandbox() {
  if (ocrSandboxFramePromise) {
    return ocrSandboxFramePromise;
  }

  ocrSandboxFramePromise = new Promise((resolve, reject) => {
    const existing = document.getElementById('clawgate-ocr-sandbox');
    if (existing instanceof HTMLIFrameElement && existing.contentWindow) {
      resolve(existing);
      return;
    }

    const iframe = document.createElement('iframe');
    iframe.id = 'clawgate-ocr-sandbox';
    iframe.src = chrome.runtime.getURL('sandbox/ocr.html');
    iframe.style.display = 'none';
    iframe.setAttribute('aria-hidden', 'true');
    iframe.addEventListener('load', () => resolve(iframe), { once: true });
    iframe.addEventListener('error', () => reject(new Error(OCR_UNAVAILABLE_REASON)), { once: true });
    (document.documentElement || document.body).appendChild(iframe);
  });

  return ocrSandboxFramePromise;
}

window.addEventListener('message', (event) => {
  if (event.origin !== getSandboxOrigin()) {
    return;
  }
  const data = event.data;
  if (!data || data.type !== 'clawgate_ocr_result' || typeof data.id !== 'string') {
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
});

async function extractOCRText(imageURL) {
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

    iframe.contentWindow?.postMessage({
      type: 'clawgate_ocr_request',
      id: requestId,
      imageDataUrl: dataUrl,
    }, getSandboxOrigin());
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
    ocrText = await extractOCRText(candidate.src);
  } catch (ocrError) {
    error = ocrError instanceof Error ? ocrError.message : String(ocrError);
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

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type !== 'extract_content') {
    return undefined;
  }

  extractPagePayload({ preferredImageURL: typeof message.preferredImageURL === 'string' ? message.preferredImageURL : '' })
    .then((payload) => sendResponse(payload))
    .catch((error) => {
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
    });

  return true;
});

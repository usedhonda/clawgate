function extractText() {
  const root = document.querySelector("article") || document.querySelector("main") || document.body;
  if (!root) return "";

  const clone = root.cloneNode(true);
  clone.querySelectorAll("script, style").forEach((node) => node.remove());

  const text = (clone.innerText || "").replace(/\s+/g, " ").trim();
  return text.slice(0, 3000);
}

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type !== "extract_content") return false;
  sendResponse({ text: extractText() });
  return false;
});

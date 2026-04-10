export async function getChromeWebContext(port = 8765) {
  const response = await fetch(`http://127.0.0.1:${port}/v1/chrome/recent-pages`);
  const data = await response.json();
  if (!data.ok || !data.result?.pages?.length) return "";

  const pages = data.result.pages;
  let text = "## Recent Web Context (ClawGate)\n";

  for (const page of pages) {
    const date = new Date(page.capturedAt).toLocaleTimeString();
    const domain = new URL(page.url).hostname;
    text += `[${date}] ${page.title} — ${domain}\n`;
  }

  if (pages[0]?.excerpt) {
    text += `\n## Active Page (just sent)\nURL: ${pages[0].url}\n---\n${pages[0].excerpt.slice(0, 500)}\n`;
  }

  return text;
}

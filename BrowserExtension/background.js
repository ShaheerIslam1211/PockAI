// Relays captions from pages to the PockAI app on this Mac (127.0.0.1 only — nothing leaves your computer).
const ENDPOINT = "http://127.0.0.1:38917/subtitle";

chrome.runtime.onMessage.addListener((msg) => {
  if (!msg || msg.type !== "pockai-subtitle") return;
  fetch(ENDPOINT, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ text: String(msg.text || "").slice(0, 600), site: msg.site || "Browser" })
  }).catch(() => { /* PockAI not running: ignore */ });
});

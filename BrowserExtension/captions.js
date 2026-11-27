// TouchPlay Subtitles — reads the captions the video player shows on screen and sends them to the Touch Bar.
(() => {
  if (window.__pockaiCaptions) return;
  window.__pockaiCaptions = true;

  const host = location.hostname;
  const SITES = [
    { name: "Netflix",     test: /netflix\.com$/,         sel: ".player-timedtext-text-container" },
    { name: "YouTube",     test: /youtube\.com$/,         sel: ".ytp-caption-window-container .caption-visual-line, .ytp-caption-segment" },
    { name: "Prime Video", test: /(primevideo|amazon)\./, sel: ".atvwebplayersdk-captions-text" },
    { name: "Disney+",     test: /disneyplus\.com$/,      sel: ".dss-subtitle-renderer-line, .hive-subtitle-renderer-line" },
    { name: "Max",         test: /(max|hbomax)\.com$/,    sel: "[data-testid='CueBoxContainer']" },
    { name: "Hulu",        test: /hulu\.com$/,            sel: ".CaptionBox, .ClosedCaption" },
    { name: "Apple TV+",   test: /tv\.apple\.com$/,       sel: ".captions-line, [class*='captions'] span" },
    { name: "Crunchyroll", test: /crunchyroll\.com$/,     sel: "[class*='subtitle'] span" }
  ];
  const site = SITES.find((s) => s.test.test(host));
  const siteName = site ? site.name : (document.title || host);

  function fromSelectors() {
    if (!site) return null;
    const nodes = Array.from(document.querySelectorAll(site.sel)).filter((n) => n.offsetParent !== null || n.getClientRects().length);
    if (!nodes.length) return "";
    // De-duplicate nested matches (YouTube line + segment).
    const texts = [];
    for (const n of nodes) {
      const t = (n.innerText || n.textContent || "").trim();
      if (t && !texts.some((x) => x.includes(t))) texts.push(t);
    }
    return texts.join("\n");
  }

  // Any HTML5 <video> with a visible text track (Vimeo, Coursera, news sites, local files…).
  function fromTextTracks() {
    const videos = document.querySelectorAll("video");
    for (const v of videos) {
      if (v.paused) continue;
      for (const track of v.textTracks || []) {
        if (track.mode !== "showing" || !track.activeCues) continue;
        const lines = Array.from(track.activeCues).map((c) => (c.text || "").replace(/<[^>]+>/g, "").trim()).filter(Boolean);
        if (lines.length) return lines.join("\n");
      }
    }
    return null;
  }

  let last = null;
  let lastSent = 0;
  function tick() {
    if (document.hidden) return;
    let text = fromSelectors();
    if (text === null || text === "") {
      const tt = fromTextTracks();
      if (tt !== null) text = tt;
    }
    if (text === null) return;
    const now = Date.now();
    // Send on change, plus a keep-alive every 5 s while captions stay on screen.
    if (text !== last || (text && now - lastSent > 5000)) {
      last = text;
      lastSent = now;
      try { chrome.runtime.sendMessage({ type: "pockai-subtitle", text, site: siteName }); } catch (e) { clearInterval(timer); }
    }
  }
  const timer = setInterval(tick, 250);
})();

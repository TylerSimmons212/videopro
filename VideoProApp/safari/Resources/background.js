/**
 * VideoPro (lite) background service worker.
 *
 * Two small jobs:
 *  1. Sniff streaming media URLs (HLS/DASH/direct) per tab via webRequest —
 *     these often never appear in the DOM, so the content script can't see them.
 *  2. Answer the popup's request for a tab's collected network URLs.
 *
 * All downloading/playback now lives in the VideoPro Mac app; this extension
 * only detects and hands off.
 */

// Match ONLY real media extensions at the end of the URL path (anchored before
// ? or end), so web-app files like `manifest.json` or `_buildManifest.js` are
// never mistaken for streams.
const APP_BASE = "http://127.0.0.1:8787";
const MEDIA_RE = /\.(m3u8|mpd|mp4|m4v|mov|webm|mkv|ts|mp3|m4a|aac|flac|ogg|oga|opus|wav)(\?|#|$)/i;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Open the app via its URL scheme (Chrome shows a one-time "Open VideoPro?"
// prompt). The throwaway tab is closed once the handoff has fired.
function openApp() {
  try {
    chrome.tabs.create({ url: "videopro://launch" }, (tab) => {
      const id = tab?.id;
      if (id) setTimeout(() => chrome.tabs.remove(id, () => void chrome.runtime.lastError), 2600);
    });
  } catch {}
}

// Launch the app if needed, then keep retrying the POST until it's up. Runs in
// the background so it survives the popup closing.
async function launchAndSend(payload) {
  openApp();
  for (let i = 0; i < 8; i++) {
    await sleep(800);
    try {
      const res = await fetch(`${APP_BASE}/videos`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      });
      const data = await res.json();
      if (data?.ok) return;
    } catch {}
  }
}

/** tabId -> Map(url -> { url, kind }) */
const perTab = new Map();

function mediaPath(url) {
  try {
    return new URL(url).pathname; // strip query so tokens can't trigger a match
  } catch {
    return "";
  }
}

function isMediaUrl(url) {
  const p = mediaPath(url);
  return !!p && MEDIA_RE.test(p);
}

function kindFor(url) {
  const p = mediaPath(url).toLowerCase();
  if (p.endsWith(".m3u8")) return "hls";
  if (p.endsWith(".mpd")) return "dash";
  if (/\.(mp3|m4a|aac|flac|ogg|oga|opus|wav)$/.test(p)) return "audio-file";
  return "file";
}

function record(tabId, url) {
  if (tabId < 0 || !url || url.startsWith("blob:") || url.startsWith("data:")) return;
  if (!isMediaUrl(url)) return;
  let map = perTab.get(tabId);
  if (!map) {
    map = new Map();
    perTab.set(tabId, map);
  }
  if (!map.has(url) && map.size < 100) {
    map.set(url, { url, kind: kindFor(url) });
  }
}

chrome.webRequest.onBeforeRequest.addListener(
  (details) => record(details.tabId, details.url),
  { urls: ["<all_urls>"] }
);

// Clear a tab's cache/badge when it navigates to a new page.
chrome.tabs.onUpdated.addListener((tabId, changeInfo) => {
  if (changeInfo.url) {
    perTab.delete(tabId);
    setBadge(tabId, 0);
  }
});
chrome.tabs.onRemoved.addListener((tabId) => perTab.delete(tabId));

// ── Toolbar badge: show how many videos are on the current tab ────────────────

chrome.action.setBadgeBackgroundColor?.({ color: "#6c5ce7" });

function setBadge(tabId, count) {
  try {
    chrome.action.setBadgeText({ tabId, text: count > 0 ? String(count) : "" });
  } catch {}
}

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg?.type === "VP_GET_NETWORK") {
    const map = perTab.get(msg.tabId);
    sendResponse({ ok: true, urls: map ? [...map.values()] : [] });
    return; // sync response
  }
  if (msg?.type === "VIDEOPRO_UPDATE" && sender.tab) {
    // Count detected video elements; if none but streams were sniffed, show 1.
    const videos = (msg.payload?.videos || []).length;
    const streams = perTab.get(sender.tab.id)?.size || 0;
    setBadge(sender.tab.id, videos || (streams ? 1 : 0));
  }
  if (msg?.type === "VP_LAUNCH_AND_SEND") {
    launchAndSend(msg.payload);
    sendResponse({ ok: true });
    return;
  }
  if (msg?.type === "VP_LAUNCH") {
    openApp();
    sendResponse({ ok: true });
    return;
  }
});

// ── Keyboard shortcut: pop out the active tab's video ─────────────────────────

chrome.commands?.onCommand.addListener((command) => {
  if (command !== "pop-out") return;
  chrome.tabs.query({ active: true, currentWindow: true }, ([tab]) => {
    if (!tab) return;
    const msg = { type: "VIDEOPRO_FOCUS", videoId: "" };
    chrome.tabs.sendMessage(tab.id, msg, { frameId: 0 }, (resp) => {
      if (!chrome.runtime.lastError && resp) return;
      // Inject on demand (tab predates the extension), then retry.
      chrome.scripting
        .executeScript({ target: { tabId: tab.id }, files: ["content.js", "focus.js"] })
        .then(() => chrome.tabs.sendMessage(tab.id, msg, { frameId: 0 }, () => void chrome.runtime.lastError))
        .catch(() => {});
    });
  });
});

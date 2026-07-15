/**
 * VideoPro (lite) popup.
 * Gathers detected videos from the active tab (content script) + sniffed
 * streaming URLs (background), then POSTs the selected ones to the Mac app.
 */

const APP_BASE = "http://127.0.0.1:8787";

const els = {
  list: document.getElementById("list"),
  empty: document.getElementById("empty"),
  sendBtn: document.getElementById("sendBtn"),
  status: document.getElementById("appStatus"),
  statusText: document.getElementById("appStatusText"),
  toast: document.getElementById("toast"),
};

let items = []; // normalized candidates: { key, video }
let appOnline = false;
let sentStore = {}; // sentKey -> timestamp

init();

async function init() {
  checkApp();
  await loadSent();
  els.sendBtn.addEventListener("click", sendAll);

  const tab = await activeTab();
  if (!tab) return renderEmpty();

  const [payload, network] = await Promise.all([
    askContent(tab.id),
    askNetwork(tab.id),
  ]);
  items = normalize(payload, network, tab);
  render(tab);
}

// ── "Already sent" memory ────────────────────────────────────────────────────

function sentKeyFor(video) {
  return video.mediaUrl || video.primarySrc || video.pageUrl || "";
}
function isSent(video) {
  const k = sentKeyFor(video);
  return !!k && !!sentStore[k];
}
function loadSent() {
  return new Promise((resolve) => {
    try {
      chrome.storage.local.get({ sentKeys: {} }, (r) => {
        sentStore = r.sentKeys || {};
        resolve();
      });
    } catch {
      resolve();
    }
  });
}
function rememberSent(videos) {
  const now = Date.now();
  for (const v of videos) {
    const k = sentKeyFor(v);
    if (k) sentStore[k] = now;
  }
  // Cap the store so it can't grow unbounded (keep newest 500).
  const entries = Object.entries(sentStore).sort((a, b) => b[1] - a[1]).slice(0, 500);
  sentStore = Object.fromEntries(entries);
  try { chrome.storage.local.set({ sentKeys: sentStore }); } catch {}
}

// ── App reachability ─────────────────────────────────────────────────────────

async function checkApp() {
  try {
    const res = await fetch(`${APP_BASE}/health`, { method: "GET" });
    const data = await res.json();
    appOnline = !!data.ok;
  } catch {
    appOnline = false;
  }
  els.status.className = "status " + (appOnline ? "status--ok" : "status--off");
  els.statusText.textContent = appOnline ? "App connected" : "Open the app";
  els.status.title = appOnline ? APP_BASE : "Click to launch the VideoPro app";
  els.status.style.cursor = appOnline ? "default" : "pointer";
  els.status.onclick = appOnline ? null : () => {
    try { chrome.runtime.sendMessage({ type: "VP_LAUNCH" }); } catch {}
    toast("Opening VideoPro…", "ok");
  };
  // Re-enable/disable card send buttons and the footer button.
  document.querySelectorAll(".act--send").forEach((b) => (b.disabled = !appOnline));
  updateSendAll();
}

// ── Data gathering ───────────────────────────────────────────────────────────

function activeTab() {
  return new Promise((resolve) => {
    chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => resolve(tabs[0]));
  });
}

function askContent(tabId) {
  return new Promise((resolve) => {
    try {
      chrome.tabs.sendMessage(tabId, { type: "VIDEOPRO_SCAN" }, () => {
        chrome.tabs.sendMessage(tabId, { type: "VIDEOPRO_GET" }, (resp) => {
          if (chrome.runtime.lastError || !resp?.ok) return resolve(null);
          resolve(resp.payload);
        });
      });
    } catch {
      resolve(null);
    }
  });
}

function askNetwork(tabId) {
  return new Promise((resolve) => {
    try {
      chrome.runtime.sendMessage({ type: "VP_GET_NETWORK", tabId }, (resp) => {
        if (chrome.runtime.lastError || !resp?.ok) return resolve([]);
        resolve(resp.urls || []);
      });
    } catch {
      resolve([]);
    }
  });
}

/** Merge element videos + network URLs into a de-duped candidate list. */
function normalize(payload, network, tab) {
  const out = [];
  const seen = new Set();
  const pageUrl = payload?.pageUrl || tab.url || "";
  const pageTitle = payload?.pageTitle || tab.title || "";

  // Known platform page (YouTube, etc.) → ONE clean item.
  if (isPlatformPage(pageUrl)) {
    return [{
      key: pageUrl,
      video: {
        title: cleanTitle(pageTitle, pageUrl) || platformLabel(pageUrl),
        pageUrl,
        pageTitle,
        thumbnail: bestThumb(payload) || deriveThumb(pageUrl),
        srcKind: "platform",
        platform: platformLabel(pageUrl),
        contentId: (payload?.videos || [])[0]?.id || "",
        canFocus: true,
      },
    }];
  }

  const title = cleanTitle(pageTitle, pageUrl);
  const firstId = (payload?.videos || [])[0]?.id || "";
  // Real per-element DRM detection (from content.js EME signals).
  const anyEncrypted = (payload?.videos || []).some((v) => v.encrypted);
  let hasBlob = false;      // page uses a blob:/MediaSource (adaptive) player
  let posterThumb = "";

  // 1) Real, directly-downloadable files: <video src="http…">.
  for (const v of payload?.videos || []) {
    const src = v.primarySrc || "";
    const thumb =
      v.thumbnail && v.thumbnail.startsWith("data:")
        ? v.thumbnail
        : v.poster && v.poster.startsWith("http")
        ? v.poster
        : "";
    if (!posterThumb && thumb) posterThumb = thumb;

    if (src.startsWith("http")) {
      if (seen.has(src)) continue;
      seen.add(src);
      out.push({
        key: src,
        video: {
          title: v.label || title,
          pageUrl, pageTitle,
          mediaUrl: src, primarySrc: src,
          srcKind: v.srcKind || "file",
          thumbnail: thumb,
          duration: v.duration || null,
          width: v.width || 0, height: v.height || 0,
          contentId: v.id || "", canFocus: true, encrypted: !!v.encrypted,
        },
      });
    } else if (
      src.startsWith("blob:") || src.startsWith("mediasource:") ||
      v.srcKind === "blob" || v.srcKind === "mediasource"
    ) {
      hasBlob = true;
    }
  }

  if (hasBlob) {
    // Adaptive/MSE player: the many sniffed HLS/DASH manifests are all variants
    // of ONE stream. Collapse to a single card for the page's video instead of
    // spamming a card per variant. Pop-out works for viewing; download routes
    // through the page URL (yt-dlp) when the site isn't DRM-protected.
    out.push({
      key: pageUrl,
      video: {
        title, pageUrl, pageTitle,
        thumbnail: posterThumb,
        srcKind: "stream",
        contentId: firstId,
        canFocus: true, encrypted: anyEncrypted,
      },
    });
  } else {
    // No MSE player — surface sniffed manifests, but dedupe variants and cap
    // the count so the list never explodes.
    for (const n of dedupeStreams(network || []).slice(0, 6)) {
      if (seen.has(n.url)) continue;
      seen.add(n.url);
      out.push({
        key: n.url,
        video: {
          title: `${title} · ${(n.kind || "stream").toUpperCase()}`,
          pageUrl, pageTitle,
          mediaUrl: n.url, primarySrc: n.url,
          srcKind: n.kind || "stream",
          thumbnail: posterThumb,
          canFocus: !!(payload?.videos || []).length,
          encrypted: anyEncrypted,
        },
      });
    }
  }

  return out;
}

// ── Rendering ────────────────────────────────────────────────────────────────

function render(tab) {
  els.list.innerHTML = "";
  if (!items.length) return renderEmpty();
  els.empty.classList.add("hidden");

  items.forEach((item) => {
    const v = item.video;
    const sent = isSent(v);
    const card = document.createElement("div");
    card.className = "card" + (sent ? " card--sent" : "");

    // Thumbnail (with a pop-out affordance when focusable)
    const thumb = document.createElement("div");
    thumb.className = "thumb";
    if (v.thumbnail && (v.thumbnail.startsWith("data:") || v.thumbnail.startsWith("http"))) {
      thumb.style.backgroundImage = `url("${v.thumbnail}")`;
    } else {
      thumb.textContent = "▶";
    }
    const overlay = document.createElement("div");
    overlay.className = "thumb-pop";
    overlay.textContent = "⤢";
    thumb.append(overlay);

    const meta = document.createElement("div");
    meta.className = "meta";
    const title = document.createElement("div");
    title.className = "title";
    title.textContent = v.title || "Untitled video";
    const tags = document.createElement("div");
    tags.className = "tags";
    if (sent) addTag(tags, "✓ Sent", "tag--sent");
    if (v.encrypted) addTag(tags, "🔒 DRM", "tag--enc");
    addTag(tags, v.platform || (v.srcKind || "").toUpperCase());
    if (v.height) addTag(tags, `${v.height}p`);
    if (v.duration) addTag(tags, fmtDuration(v.duration));
    const host = document.createElement("div");
    host.className = "host";
    host.textContent = hostOf(v.mediaUrl || v.pageUrl);
    meta.append(title, tags, host);

    // Clicking the thumb/meta pops the video out into focus mode.
    const zone = document.createElement("div");
    zone.className = "zone zone--focus";
    zone.append(thumb, meta);
    zone.addEventListener("click", () => focusVideo(item));

    // Per-card actions
    const actions = document.createElement("div");
    actions.className = "actions";
    const pop = document.createElement("button");
    pop.className = "act";
    pop.title = "Pop out & play in focus mode";
    pop.textContent = "⤢";
    pop.addEventListener("click", (e) => { e.stopPropagation(); focusVideo(item); });
    actions.append(pop);
    const send = document.createElement("button");
    send.className = "act act--send";
    // We always allow the attempt — yt-dlp is the judge (some "encrypted" media,
    // like YouTube, still downloads). Just hint when it's DRM-protected.
    send.title = v.encrypted
      ? "Send to VideoPro (DRM may prevent download)"
      : "Send to the VideoPro app";
    send.disabled = !appOnline;
    send.textContent = "⬇";
    send.addEventListener("click", (e) => { e.stopPropagation(); sendOne(item, send); });
    actions.append(send);

    card.append(zone, actions);
    els.list.append(card);
  });

  updateSendAll();
}

function renderEmpty() {
  els.list.innerHTML = "";
  els.empty.classList.remove("hidden");
  updateSendAll();
}

function addTag(container, text, extraClass) {
  if (!text) return;
  const t = document.createElement("span");
  t.className = "tag" + (extraClass ? " " + extraClass : "");
  t.textContent = text;
  container.append(t);
}

// ── Focus (pop out) ──────────────────────────────────────────────────────────

function sendFocus(tabId, videoId) {
  return new Promise((resolve) => {
    // Top frame only — avoids ad/iframe listeners racing to answer "not found".
    chrome.tabs.sendMessage(tabId, { type: "VIDEOPRO_FOCUS", videoId }, { frameId: 0 }, (resp) => {
      resolve({ err: chrome.runtime.lastError, resp });
    });
  });
}

async function focusVideo(item) {
  const tab = await activeTab();
  if (!tab) return;
  const videoId = item.video.contentId || "";

  let { err, resp } = await sendFocus(tab.id, videoId);

  // focus.js may not be injected (tab was open before the extension updated).
  // Inject it on demand, then retry — the script is idempotent.
  if (err) {
    try {
      await chrome.scripting.executeScript({
        target: { tabId: tab.id },   // top frame
        files: ["content.js", "focus.js"],
      });
      ({ err, resp } = await sendFocus(tab.id, videoId));
    } catch (e) {
      toast("Can't run on this page (try a normal website).", "err");
      return;
    }
  }

  if (err || !resp?.ok) {
    toast(resp?.error || "No playable video found on the page.", "err");
    return;
  }
  window.close(); // get out of the way so they can watch
}

// ── Send ─────────────────────────────────────────────────────────────────────

function sendableVideos() {
  // Allow everything except already-sent — yt-dlp decides what's downloadable.
  return items.map((it) => it.video).filter((v) => !isSent(v));
}

function updateSendAll() {
  const n = sendableVideos().length;
  els.sendBtn.disabled = !appOnline || n === 0;
  els.sendBtn.textContent = n > 1 ? `Send all (${n})` : "Send all";
}

async function postVideos(videos) {
  const tab = await activeTab();
  const res = await fetch(`${APP_BASE}/videos`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ pageUrl: tab?.url || "", pageTitle: tab?.title || "", videos }),
  });
  return { data: await res.json(), tab };
}

// App offline → hand off to the background to launch the app and deliver once
// it's up (survives this popup closing).
async function delegateLaunchSend(videos) {
  const tab = await activeTab();
  try {
    chrome.runtime.sendMessage({
      type: "VP_LAUNCH_AND_SEND",
      payload: { pageUrl: tab?.url || "", pageTitle: tab?.title || "", videos },
    });
  } catch {}
  rememberSent(videos);
  toast("Opening VideoPro…", "ok");
  setTimeout(() => window.close(), 1300);
}

async function sendOne(item, btn) {
  if (btn) btn.disabled = true;
  try {
    const { data, tab } = await postVideos([item.video]);
    if (data.ok) {
      rememberSent([item.video]);
      render(tab);
      toast("Sent to VideoPro", "ok");
    } else {
      toast(data.error || "App rejected the request", "err");
    }
  } catch {
    delegateLaunchSend([item.video]);
  }
}

async function sendAll() {
  const videos = sendableVideos();
  if (!videos.length) return;
  els.sendBtn.disabled = true;
  try {
    const { data, tab } = await postVideos(videos);
    if (data.ok) {
      rememberSent(videos);
      render(tab);
      toast(`Sent ${data.count} to VideoPro`, "ok");
      setTimeout(() => window.close(), 1100);
    } else {
      toast(data.error || "App rejected the request", "err");
      updateSendAll();
    }
  } catch {
    delegateLaunchSend(videos);
  }
}

function toast(msg, kind) {
  els.toast.textContent = msg;
  els.toast.className = "toast " + (kind || "");
  setTimeout(() => els.toast.classList.add("hidden"), 2500);
}

// ── Helpers ──────────────────────────────────────────────────────────────────

const PLATFORM_HOSTS = [
  "youtube.com", "youtu.be", "vimeo.com", "tiktok.com", "instagram.com",
  "twitter.com", "x.com", "reddit.com", "soundcloud.com", "twitch.tv",
  "facebook.com", "fb.watch", "dailymotion.com", "streamable.com",
  "bilibili.com", "vk.com", "bsky.app",
];

function bestThumb(payload) {
  for (const v of payload?.videos || []) {
    if (v.thumbnail && v.thumbnail.startsWith("data:")) return v.thumbnail;
    if (v.poster && v.poster.startsWith("http")) return v.poster;
  }
  return "";
}
function youtubeIdFromUrl(url) {
  try {
    const u = new URL(url);
    const h = u.hostname.replace(/^www\./, "");
    if (h === "youtu.be") {
      const id = u.pathname.split("/").filter(Boolean)[0];
      return /^[\w-]{11}$/.test(id) ? id : "";
    }
    if (h.includes("youtube.com")) {
      const v = u.searchParams.get("v");
      if (v && /^[\w-]{11}$/.test(v)) return v;
      const m = u.pathname.match(/\/(?:embed|shorts|live|v)\/([\w-]{11})/);
      if (m) return m[1];
    }
  } catch {}
  return "";
}
/** Best-effort preview image derived from the page URL (YouTube only, no API). */
function deriveThumb(pageUrl) {
  const id = youtubeIdFromUrl(pageUrl);
  return id ? `https://i.ytimg.com/vi/${id}/hqdefault.jpg` : "";
}
function hostOf(url) {
  try { return new URL(url).hostname.replace(/^www\./, ""); } catch { return ""; }
}

// Generic framework/placeholder titles we should replace with something useful.
const JUNK_TITLES = new Set([
  "", "create next app", "react app", "vite app", "video", "untitled",
  "loading", "loading…", "loading...", "home", "index",
]);
function cleanTitle(t, pageUrl) {
  const trimmed = (t || "").trim();
  if (trimmed && !JUNK_TITLES.has(trimmed.toLowerCase())) return trimmed;
  return hostOf(pageUrl) || "Video";
}

/** Collapse HLS/DASH variants: keep one representative per origin+first path dir. */
function dedupeStreams(list) {
  const byKey = new Map();
  for (const n of list) {
    let key;
    try {
      const u = new URL(n.url);
      key = u.origin + "/" + u.pathname.split("/").filter(Boolean).slice(0, 2).join("/");
    } catch { key = n.url; }
    const prev = byKey.get(key);
    // Prefer a master/index playlist as the representative of the group.
    if (!prev || /master|playlist|index|manifest/i.test(n.url)) byKey.set(key, n);
  }
  return [...byKey.values()];
}
function isPlatformPage(url) {
  const h = hostOf(url);
  return PLATFORM_HOSTS.some((p) => h === p || h.endsWith("." + p));
}
function platformLabel(url) {
  const h = hostOf(url);
  if (h.includes("youtu")) return "YouTube";
  if (h.includes("vimeo")) return "Vimeo";
  if (h.includes("tiktok")) return "TikTok";
  if (h.includes("instagram")) return "Instagram";
  if (h === "x.com" || h.includes("twitter")) return "X";
  if (h.includes("reddit")) return "Reddit";
  if (h.includes("twitch")) return "Twitch";
  if (h.includes("facebook") || h.includes("fb.watch")) return "Facebook";
  return h.split(".")[0] || "Platform";
}
function fmtDuration(sec) {
  sec = Math.round(sec);
  const h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60), s = sec % 60;
  return h > 0
    ? `${h}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`
    : `${m}:${String(s).padStart(2, "0")}`;
}

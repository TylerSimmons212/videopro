/**
 * VideoPro content script
 * Detects media, captures thumbnails, scans resource URLs, handles local actions.
 */

(() => {
  if (window.__videoproInjected) return;
  window.__videoproInjected = true;

  const FRAME_ID = crypto.randomUUID();
  /** @type {Map<string, { el: HTMLMediaElement, type: string, thumbnail: string }>} */
  const elements = new Map();
  let observer = null;
  let pollTimer = null;
  let lastPayloadHash = "";
  const resourceUrls = new Map(); // url -> { url, mimeType }

  // ─── helpers ───────────────────────────────────────────────────────────────

  function uid() {
    return `vp_${Math.random().toString(36).slice(2, 10)}`;
  }

  function collectSrcs(el) {
    const srcs = new Set();
    if (el.currentSrc) srcs.add(el.currentSrc);
    if (el.src) srcs.add(el.src);
    el.querySelectorAll("source[src]").forEach((s) => {
      if (s.src) srcs.add(s.src);
    });
    return [...srcs].filter(Boolean);
  }

  function classifyUrl(url) {
    if (!url) return "unknown";
    if (url.startsWith("blob:")) return "blob";
    if (url.startsWith("data:")) return "data";
    if (url.startsWith("mediasource:")) return "mediasource";
    try {
      const u = new URL(url, location.href);
      const path = u.pathname.toLowerCase();
      const full = (path + u.search).toLowerCase();
      if (full.includes(".m3u8")) return "hls";
      if (full.includes(".mpd")) return "dash";
      if (/\.(mp4|webm|ogg|ogv|mov|m4v|mkv)(\?|$)/i.test(path)) return "file";
      if (/\.(mp3|wav|aac|flac|m4a|opus)(\?|$)/i.test(path)) return "audio-file";
    } catch {
      /* ignore */
    }
    return "stream";
  }

  function isInterestingMediaUrl(url) {
    if (!url || url.startsWith("blob:") || url.startsWith("data:")) return false;
    const kind = classifyUrl(url);
    if (["hls", "dash", "file", "audio-file"].includes(kind)) return true;
    try {
      const u = new URL(url, location.href);
      // Only real streaming manifests / media files by extension on the PATH —
      // never bare "manifest"/"playlist" substrings (those match manifest.json,
      // _buildManifest.js, and other non-media web-app files).
      if (/\.(m3u8|mpd)(\?|#|$)/i.test(u.pathname)) return true;
      if (/\.(mp4|m4v|mov|webm|mkv|ts|m4a|mp3|aac|flac|ogg|opus|wav)(\?|#|$)/i.test(u.pathname)) return true;
    } catch {
      /* */
    }
    return false;
  }

  function safeDuration(el) {
    const d = el.duration;
    if (!Number.isFinite(d) || d <= 0) return null;
    return d;
  }

  function getTracks(el) {
    const tracks = [];
    if (!el.textTracks) return tracks;
    for (let i = 0; i < el.textTracks.length; i++) {
      const t = el.textTracks[i];
      tracks.push({
        index: i,
        kind: t.kind,
        label: t.label || "",
        language: t.language || "",
        mode: t.mode,
        cueCount: t.cues ? t.cues.length : 0,
      });
    }
    el.querySelectorAll("track").forEach((tr, i) => {
      const kind = tr.kind || "subtitles";
      const already = tracks.some(
        (t) => t.language === (tr.srclang || "") && t.kind === kind
      );
      if (!already) {
        tracks.push({
          index: tracks.length + i,
          kind,
          label: tr.label || "",
          language: tr.srclang || "",
          mode: "disabled",
          cueCount: 0,
          src: tr.src || "",
        });
      }
    });
    return tracks;
  }

  function getLabel(el) {
    return (
      el.getAttribute("aria-label") ||
      el.getAttribute("title") ||
      el.getAttribute("data-title") ||
      ""
    );
  }

  function extractYouTubeId(url = location.href) {
    try {
      const u = new URL(url);
      const host = u.hostname.replace(/^www\./, "");
      if (host === "youtu.be") {
        const id = u.pathname.split("/").filter(Boolean)[0];
        return id && /^[\w-]{11}$/.test(id) ? id : null;
      }
      if (host.includes("youtube.com")) {
        const v = u.searchParams.get("v");
        if (v && /^[\w-]{11}$/.test(v)) return v;
        const m = u.pathname.match(/\/(?:embed|shorts|live|v)\/([\w-]{11})/);
        if (m) return m[1];
      }
    } catch {
      /* */
    }
    return null;
  }

  // ─── Thumbnails ────────────────────────────────────────────────────────────

  function captureThumbnail(el, entry) {
    if (!el || el.tagName !== "VIDEO") return "";
    if (el.readyState < 2) return entry?.thumbnail || "";
    const w = el.videoWidth;
    const h = el.videoHeight;
    if (!w || !h) return entry?.thumbnail || "";

    // Cross-origin without CORS taints canvas — fail quietly
    try {
      const maxW = 160;
      const scale = Math.min(1, maxW / w);
      const cw = Math.max(1, Math.round(w * scale));
      const ch = Math.max(1, Math.round(h * scale));
      const canvas = document.createElement("canvas");
      canvas.width = cw;
      canvas.height = ch;
      const ctx = canvas.getContext("2d");
      ctx.drawImage(el, 0, 0, cw, ch);
      const data = canvas.toDataURL("image/jpeg", 0.62);
      if (entry) entry.thumbnail = data;
      return data;
    } catch {
      return entry?.thumbnail || el.poster || "";
    }
  }

  function scheduleThumb(el, entry) {
    const tryCap = () => {
      if (!el.isConnected) return;
      const t = captureThumbnail(el, entry);
      if (t) publish(false);
    };
    if (el.readyState >= 2) {
      // Wait a tick so a decoded frame exists
      requestAnimationFrame(tryCap);
    } else {
      el.addEventListener("loadeddata", tryCap, { once: true });
      el.addEventListener("seeked", tryCap, { once: true });
    }
  }

  // ─── App handoff via the videopro:// URL scheme ────────────────────────────
  //
  // Safari does not let an extension reach 127.0.0.1, so the POST to the local
  // server that works in Chrome always fails there. macOS will still route our
  // registered custom scheme to the app (launching it if needed), so we encode
  // the payload into a videopro://add URL as a fallback.
  //
  // Exposed on `window` because content scripts of the same extension share one
  // isolated world — focus.js reuses this rather than duplicating it.

  const SCHEME_URL_LIMIT = 8000; // stay well clear of any URL length ceiling

  function b64url(str) {
    // btoa() is latin1-only; encode UTF-8 by hand so non-ASCII titles survive.
    const bytes = new TextEncoder().encode(str);
    let bin = "";
    for (const b of bytes) bin += String.fromCharCode(b);
    return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  }

  function encodeSchemeURL(payload) {
    // Deliberately drop thumbnails: base64 frames are enormous and would blow the
    // URL limit. The app fetches a better one via yt-dlp during enrichment anyway.
    const slim = {
      pageUrl: payload.pageUrl || "",
      pageTitle: payload.pageTitle || "",
      videos: (payload.videos || []).map((v) => ({
        title: v.title || "",
        pageUrl: v.pageUrl || "",
        pageTitle: v.pageTitle || "",
        mediaUrl: v.mediaUrl || v.primarySrc || "",
        srcKind: v.srcKind || "stream",
        duration: typeof v.duration === "number" ? v.duration : null,
        width: v.width || 0,
        height: v.height || 0,
        platform: v.platform || null,
      })),
    };
    return `videopro://add?v=${b64url(JSON.stringify(slim))}`;
  }

  function openScheme(url) {
    // Navigate a hidden iframe rather than the page — `location = "videopro://"`
    // would blank out whatever the user was watching.
    try {
      const f = document.createElement("iframe");
      f.style.display = "none";
      f.src = url;
      (document.body || document.documentElement).appendChild(f);
      setTimeout(() => f.remove(), 2000);
      return true;
    } catch {
      return false;
    }
  }

  function sendViaScheme(payload) {
    // NB: no top-frame guard here on purpose. focus.js legitimately calls this
    // from whichever frame owns the video (an embedded player lives in an
    // iframe), and that frame's location.href is the correct page for it. The
    // duplicate-launch risk comes from *broadcasting*, which the popup avoids by
    // targeting frameId 0.
    let url = encodeSchemeURL(payload);
    if (url.length > SCHEME_URL_LIMIT) {
      // Too long (usually a huge signed media URL). Fall back to just the page —
      // yt-dlp can resolve it from that alone.
      url = encodeSchemeURL({
        pageUrl: payload.pageUrl,
        pageTitle: payload.pageTitle,
        videos: [
          {
            title: payload.pageTitle || location.hostname,
            pageUrl: payload.pageUrl || location.href,
            srcKind: "page",
          },
        ],
      });
    }
    return openScheme(url);
  }

  window.__videoproSendViaScheme = sendViaScheme;

  // ─── Resource / Performance scan (complements webRequest) ──────────────────

  // A long HLS/DASH session emits thousands of segment URLs. We only ever need a
  // recent window of them, and every publish() stringifies this map — so cap it
  // (oldest out first) instead of letting it grow for the life of the tab.
  const MAX_RESOURCE_URLS = 300;

  function noteResource(url, mimeType = "") {
    if (!isInterestingMediaUrl(url)) return;
    try {
      const abs = new URL(url, location.href).href;
      if (!resourceUrls.has(abs)) {
        resourceUrls.set(abs, { url: abs, mimeType });
        while (resourceUrls.size > MAX_RESOURCE_URLS) {
          resourceUrls.delete(resourceUrls.keys().next().value);
        }
      }
    } catch {
      /* */
    }
  }

  // performance.getEntriesByType("resource") returns the whole buffer every call,
  // so re-reading it from index 0 on a timer means O(n²) work over a session.
  // Only look at entries we haven't seen yet.
  let perfCursor = 0;
  function scanPerformanceResources() {
    try {
      const entries = performance.getEntriesByType("resource");
      for (let i = perfCursor; i < entries.length; i++) {
        const e = entries[i];
        noteResource(e.name, e.initiatorType === "video" ? "video/*" : "");
      }
      perfCursor = entries.length;
      // The buffer can be cleared by the page; don't strand the cursor past its end.
      if (perfCursor > entries.length) perfCursor = 0;
    } catch {
      /* */
    }
  }

  function startResourceObserver() {
    try {
      const po = new PerformanceObserver((list) => {
        for (const e of list.getEntries()) {
          noteResource(e.name);
        }
        // Publish network batch occasionally
        flushNetworkUrls();
      });
      po.observe({ type: "resource", buffered: true });
    } catch {
      /* older */
    }

    // Patch fetch lightly for m3u8/mpd in this frame
    try {
      const origFetch = window.fetch;
      if (origFetch && !window.__videoproFetchPatched) {
        window.__videoproFetchPatched = true;
        window.fetch = function patchedFetch(input, init) {
          try {
            const u = typeof input === "string" ? input : input?.url;
            if (u) noteResource(u);
          } catch {
            /* */
          }
          return origFetch.apply(this, arguments);
        };
      }
    } catch {
      /* */
    }
  }

  let networkFlushTimer = null;
  function flushNetworkUrls() {
    if (networkFlushTimer) return;
    networkFlushTimer = setTimeout(() => {
      networkFlushTimer = null;
      if (!resourceUrls.size) return;
      const urls = [...resourceUrls.values()];
      try {
        chrome.runtime.sendMessage({
          type: "VIDEOPRO_NETWORK_URLS",
          urls,
          pageUrl: location.href,
          pageTitle: document.title || "",
        });
      } catch {
        /* */
      }
    }, 400);
  }

  // ─── Serialize / publish ───────────────────────────────────────────────────

  function serialize(id, entry) {
    const el = entry.el;
    const srcs = collectSrcs(el);
    const primary = el.currentSrc || srcs[0] || "";
    const type = entry.type;
    const isVideo = type === "video";
    const thumb =
      entry.thumbnail ||
      (isVideo ? el.poster || "" : "") ||
      "";

    return {
      id,
      frameId: FRAME_ID,
      type,
      tag: el.tagName.toLowerCase(),
      srcs,
      primarySrc: primary,
      srcKind: classifyUrl(primary),
      poster: isVideo ? el.poster || "" : "",
      thumbnail: thumb.startsWith("data:") ? thumb : thumb,
      duration: safeDuration(el),
      currentTime: Number.isFinite(el.currentTime) ? el.currentTime : 0,
      paused: !!el.paused,
      ended: !!el.ended,
      muted: !!el.muted,
      volume: el.volume,
      playbackRate: el.playbackRate,
      width: isVideo ? el.videoWidth || 0 : 0,
      height: isVideo ? el.videoHeight || 0 : 0,
      readyState: el.readyState,
      networkState: el.networkState,
      label: getLabel(el),
      tracks: getTracks(el),
      pageUrl: location.href,
      pageTitle: document.title || "",
      isTopFrame: window === window.top,
      frameUrl: location.href,
      youtubeId: extractYouTubeId(),
      encrypted: !!(entry.encrypted || el.mediaKeys),
      fromNetwork: false,
    };
  }

  function buildPayload() {
    const videos = [];
    for (const [id, entry] of elements) {
      if (!entry.el.isConnected) {
        elements.delete(id);
        continue;
      }
      videos.push(serialize(id, entry));
    }
    videos.sort((a, b) => {
      if (a.paused !== b.paused) return a.paused ? 1 : -1;
      const as = a.primarySrc ? 1 : 0;
      const bs = b.primarySrc ? 1 : 0;
      if (as !== bs) return bs - as;
      return b.width * b.height - a.width * a.height;
    });
    return {
      frameId: FRAME_ID,
      pageUrl: location.href,
      pageTitle: document.title || "",
      isTopFrame: window === window.top,
      videos,
      networkUrls: [...resourceUrls.values()],
      ts: Date.now(),
    };
  }

  function publish(force = false) {
    const payload = buildPayload();
    const hash = JSON.stringify({
      v: payload.videos.map((v) => ({
        id: v.id,
        primarySrc: v.primarySrc,
        paused: v.paused,
        currentTime: Math.floor(v.currentTime),
        duration: v.duration,
        width: v.width,
        height: v.height,
        tracks: v.tracks?.length,
        hasThumb: !!(v.thumbnail && v.thumbnail.startsWith("data:")),
        enc: v.encrypted,
      })),
      n: payload.networkUrls.length,
    });
    if (!force && hash === lastPayloadHash) return;
    lastPayloadHash = hash;
    try {
      chrome.runtime.sendMessage({ type: "VIDEOPRO_UPDATE", payload });
    } catch {
      /* extension reloaded */
    }
  }

  // ─── discovery ─────────────────────────────────────────────────────────────

  function attach(el) {
    if (el.__videoproId) return;
    const type = el.tagName === "AUDIO" ? "audio" : "video";
    const id = uid();
    el.__videoproId = id;
    const entry = { el, type, thumbnail: "", encrypted: false };
    elements.set(id, entry);

    // Real DRM detection via EME (Encrypted Media Extensions): the browser fires
    // "encrypted" when the media stream is protected, and sets `mediaKeys` when a
    // key system (Widevine/FairPlay/PlayReady) is attached. This is per-element
    // and works on any site — no domain guessing.
    el.addEventListener("encrypted", () => {
      if (!entry.encrypted) {
        entry.encrypted = true;
        publish(true);
      }
    });

    const onChange = () => publish();
    [
      "play",
      "pause",
      "ended",
      "loadedmetadata",
      "durationchange",
      "ratechange",
      "volumechange",
      "emptied",
      "loadstart",
    ].forEach((evt) => {
      el.addEventListener(evt, onChange);
    });

    if (type === "video") scheduleThumb(el, entry);
  }

  /**
   * Walk a subtree for media, descending into shadow roots.
   *
   * PERF: this is deliberately NOT `querySelectorAll("*")`. Walking every element
   * looking for `.shadowRoot` costs ~6.6ms on a 30k-node page; run per mutation on
   * a busy SPA that saturates the main thread and the tab gets killed. A TreeWalker
   * over the subtree that actually changed is thousands of times cheaper.
   */
  function scanSubtree(root) {
    if (!root) return;
    if (root.nodeType === 1) {
      if (root.tagName === "VIDEO" || root.tagName === "AUDIO") attach(root);
      if (root.shadowRoot) scanSubtree(root.shadowRoot);
    }
    if (!root.querySelectorAll) return;
    root.querySelectorAll("video, audio").forEach(attach);

    // Shadow hosts can't be found with a selector, so we do have to walk — but
    // only within the changed subtree, and only when one might exist.
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT);
    for (let n = walker.nextNode(); n; n = walker.nextNode()) {
      if (n.shadowRoot) scanSubtree(n.shadowRoot);
    }
  }

  /** Full-document sweep. Only for boot / explicit rescans — never per mutation. */
  function scan(root = document) {
    scanSubtree(root);
    reapDetached();
    flushNetworkUrls();
  }

  // Coalesce mutation bursts into one pass per frame. Without this an SPA feed
  // fires hundreds of batches a second and we'd do the work on every one.
  let pendingRoots = [];
  let scanScheduled = false;
  function scheduleScan(roots) {
    if (roots && roots.length) pendingRoots.push(...roots);
    if (scanScheduled) return;
    scanScheduled = true;
    requestAnimationFrame(() => {
      scanScheduled = false;
      const roots = pendingRoots;
      pendingRoots = [];
      for (const r of roots) {
        if (r && r.isConnected !== false) scanSubtree(r);
      }
      publish();
    });
  }

  function startObserver() {
    if (observer) return;
    observer = new MutationObserver((mutations) => {
      const roots = [];
      for (const m of mutations) {
        if (m.addedNodes && m.addedNodes.length) {
          for (const n of m.addedNodes) if (n.nodeType === 1) roots.push(n);
        }
        if (
          m.type === "attributes" &&
          (m.target.tagName === "VIDEO" ||
            m.target.tagName === "AUDIO" ||
            m.target.tagName === "SOURCE")
        ) {
          roots.push(m.target);
        }
      }
      if (roots.length) scheduleScan(roots);
    });
    observer.observe(document.documentElement || document.body, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ["src", "poster"],
    });
  }

  /**
   * Drop elements that have left the DOM. `elements` holds hard references to
   * media nodes plus their base64 thumbnails, so without this an SPA that swaps
   * players on every navigation leaks them forever until the tab runs out of memory.
   */
  function reapDetached() {
    for (const [id, entry] of elements) {
      if (!entry.el || !entry.el.isConnected) elements.delete(id);
    }
  }

  function getEntry(id) {
    const entry = elements.get(id);
    if (!entry || !entry.el.isConnected) return null;
    return entry;
  }

  // ─── Transcripts ───────────────────────────────────────────────────────────

  async function exportTranscript(el, trackIndex) {
    const result = {
      cues: [],
      format: "vtt",
      text: "",
      error: null,
      source: "element",
    };

    if (el.textTracks && el.textTracks.length) {
      let track = null;
      if (typeof trackIndex === "number" && el.textTracks[trackIndex]) {
        track = el.textTracks[trackIndex];
      } else {
        track =
          [...el.textTracks].find(
            (t) => t.kind === "captions" || t.kind === "subtitles"
          ) || el.textTracks[0];
      }
      if (track) {
        const prev = track.mode;
        if (track.mode === "disabled") track.mode = "hidden";
        await new Promise((r) => setTimeout(r, 80));
        const cues = track.cues;
        if (cues && cues.length) {
          for (let i = 0; i < cues.length; i++) {
            const c = cues[i];
            result.cues.push({
              start: c.startTime,
              end: c.endTime,
              text: (c.text || "").replace(/\n/g, " ").trim(),
            });
          }
        }
        track.mode = prev;
      }
    }

    if (!result.cues.length) {
      const trackEls = [...el.querySelectorAll("track[src]")];
      const preferred =
        trackEls.find(
          (t) => (t.kind || "") === "captions" || (t.kind || "") === "subtitles"
        ) || trackEls[0];
      if (preferred?.src) {
        try {
          const res = await fetch(preferred.src);
          if (res.ok) {
            const body = await res.text();
            result.text = body;
            result.format = preferred.src.toLowerCase().includes(".srt")
              ? "srt"
              : "vtt";
            result.cues = parseVttLike(body);
          }
        } catch (e) {
          result.error = `Could not fetch track: ${e.message}`;
        }
      }
    }

    if (result.cues.length && !result.text) {
      result.text = cuesToVtt(result.cues);
      result.format = "vtt";
    }
    if (!result.cues.length && !result.text) {
      result.error =
        result.error || "No captions/subtitles found on this media element.";
    }
    return result;
  }

  function parseVttLike(body) {
    const cues = [];
    const lines = body.replace(/\r/g, "").split("\n");
    let i = 0;
    while (i < lines.length) {
      const line = lines[i];
      if (line.includes("-->")) {
        const [startRaw, endRaw] = line.split("-->").map((s) => s.trim());
        const start = parseTs(startRaw);
        const end = parseTs(endRaw.split(/\s+/)[0]);
        i++;
        const textLines = [];
        while (i < lines.length && lines[i].trim() !== "") {
          textLines.push(lines[i]);
          i++;
        }
        cues.push({ start, end, text: textLines.join(" ").trim() });
      }
      i++;
    }
    return cues;
  }

  function parseTs(ts) {
    const parts = ts.replace(",", ".").split(":");
    if (parts.length === 3) {
      return +parts[0] * 3600 + +parts[1] * 60 + parseFloat(parts[2]);
    }
    if (parts.length === 2) {
      return +parts[0] * 60 + parseFloat(parts[1]);
    }
    return parseFloat(ts) || 0;
  }

  function cuesToVtt(cues) {
    const fmt = (t) => {
      const h = Math.floor(t / 3600);
      const m = Math.floor((t % 3600) / 60);
      const s = t % 60;
      const whole = Math.floor(s);
      const ms = Math.round((s - whole) * 1000);
      return `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}:${String(whole).padStart(2, "0")}.${String(ms).padStart(3, "0")}`;
    };
    let out = "WEBVTT\n\n";
    cues.forEach((c, i) => {
      out += `${i + 1}\n${fmt(c.start)} --> ${fmt(c.end)}\n${c.text}\n\n`;
    });
    return out;
  }

  // ─── Messages ──────────────────────────────────────────────────────────────

  chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
    if (!msg || !msg.type) return;

    if (msg.type === "VIDEOPRO_PING") {
      sendResponse({ ok: true, frameId: FRAME_ID });
      return;
    }

    // The popup can't open a custom scheme itself (and Safari blocks its
    // localhost POST), so it delegates the handoff down to us.
    if (msg.type === "VIDEOPRO_SEND_VIA_SCHEME") {
      sendResponse({ ok: sendViaScheme(msg.payload || {}) });
      return;
    }

    if (msg.type === "VIDEOPRO_SCAN") {
      scan();
      publish(true);
      sendResponse({ ok: true, count: elements.size });
      return;
    }

    if (msg.type === "VIDEOPRO_GET") {
      sendResponse({ ok: true, payload: buildPayload() });
      return;
    }

    if (msg.type === "VIDEOPRO_ACTION") {
      const { action, videoId, value } = msg;
      const entry = getEntry(videoId);
      if (!entry) {
        sendResponse({
          ok: false,
          error: "Video not found (page may have changed).",
        });
        return;
      }
      const el = entry.el;

      (async () => {
        try {
          switch (action) {
            case "play":
              await el.play();
              break;
            case "pause":
              el.pause();
              break;
            case "toggle":
              if (el.paused) await el.play();
              else el.pause();
              break;
            case "mute":
              el.muted = true;
              break;
            case "unmute":
              el.muted = false;
              break;
            case "seek":
              if (typeof value === "number") el.currentTime = value;
              break;
            case "rate":
              if (typeof value === "number") el.playbackRate = value;
              break;
            case "pip": {
              if (el.tagName !== "VIDEO")
                throw new Error("PiP only works on video.");
              if (document.pictureInPictureElement === el) {
                await document.exitPictureInPicture();
              } else {
                await el.requestPictureInPicture();
              }
              break;
            }
            case "scroll":
              el.scrollIntoView({ behavior: "smooth", block: "center" });
              el.style.outline = "3px solid #6c5ce7";
              setTimeout(() => {
                el.style.outline = "";
              }, 1600);
              break;
            case "thumbnail": {
              const data = captureThumbnail(el, entry);
              if (!data) throw new Error("Could not capture frame (not ready or CORS).");
              sendResponse({ ok: true, thumbnail: data });
              publish(true);
              return;
            }
            case "transcript": {
              const data = await exportTranscript(el, value?.trackIndex);
              sendResponse({
                ok: !data.error || !!data.text,
                transcript: data,
              });
              publish();
              return;
            }
            default:
              throw new Error(`Unknown action: ${action}`);
          }
          publish(true);
          sendResponse({ ok: true });
        } catch (e) {
          sendResponse({ ok: false, error: e.message || String(e) });
        }
      })();
      return true;
    }
  });

  // ─── boot ──────────────────────────────────────────────────────────────────

  function boot() {
    scan();
    startObserver();
    startResourceObserver();
    publish(true);
    if (pollTimer) clearInterval(pollTimer);
    pollTimer = setInterval(() => {
      // Resource sweeping lives here, not in scan() — it must not run per mutation.
      scanPerformanceResources();
      reapDetached();
      // retry thumbs for videos still missing one
      for (const entry of elements.values()) {
        if (
          entry.type === "video" &&
          !entry.thumbnail &&
          entry.el.readyState >= 2
        ) {
          captureThumbnail(entry.el, entry);
        }
      }
      publish(false);
      flushNetworkUrls();
    }, 1500);
  }

  window.addEventListener("videopro-scan", () => {
    scan();
    publish(true);
  });

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", boot, { once: true });
  } else {
    boot();
  }
})();

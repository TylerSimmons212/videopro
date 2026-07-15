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

  // ─── Resource / Performance scan (complements webRequest) ──────────────────

  function noteResource(url, mimeType = "") {
    if (!isInterestingMediaUrl(url)) return;
    try {
      const abs = new URL(url, location.href).href;
      if (!resourceUrls.has(abs)) {
        resourceUrls.set(abs, { url: abs, mimeType });
      }
    } catch {
      /* */
    }
  }

  function scanPerformanceResources() {
    try {
      const entries = performance.getEntriesByType("resource");
      for (const e of entries) {
        noteResource(e.name, e.initiatorType === "video" ? "video/*" : "");
      }
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

  function scan(root = document) {
    if (!root || !root.querySelectorAll) return;
    root.querySelectorAll("video, audio").forEach(attach);
    root.querySelectorAll("*").forEach((node) => {
      if (node.shadowRoot) scan(node.shadowRoot);
    });
    scanPerformanceResources();
    flushNetworkUrls();
  }

  function startObserver() {
    if (observer) return;
    observer = new MutationObserver((mutations) => {
      let needScan = false;
      for (const m of mutations) {
        if (m.addedNodes?.length) needScan = true;
        if (
          m.type === "attributes" &&
          (m.target.tagName === "VIDEO" ||
            m.target.tagName === "AUDIO" ||
            m.target.tagName === "SOURCE")
        ) {
          needScan = true;
        }
      }
      if (needScan) {
        scan();
        publish();
      }
    });
    observer.observe(document.documentElement || document.body, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ["src", "poster"],
    });
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

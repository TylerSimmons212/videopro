/**
 * VideoPro — Focus mode.
 *
 * Pops a page's <video> out of its surroundings into a full-viewport, dimmed
 * "theater" overlay with a clean custom control bar. The real element is moved
 * (so any source works — direct, blob, or MSE) into a Shadow DOM stage so page
 * CSS can't fight our UI, and restored to its exact original spot on close.
 */

(() => {
  if (window.__videoproFocus) return;
  window.__videoproFocus = true;

  const APP_BASE = "http://127.0.0.1:8787";
  let host = null, root = null, video = null, restore = null, raf = 0;

  // ── element lookup ─────────────────────────────────────────────────────────
  function findVideo(id) {
    const all = [...document.querySelectorAll("video")];
    if (id) {
      const match = all.find((v) => v.__videoproId === id);
      if (match) return match;
    }
    // Fallback: the most "important" video (playing & largest).
    return (
      all
        .filter((v) => v.readyState > 0 || v.currentSrc || v.src)
        .sort((a, b) => {
          if (a.paused !== b.paused) return a.paused ? 1 : -1;
          return b.clientWidth * b.clientHeight - a.clientWidth * a.clientHeight;
        })[0] || all[0] || null
    );
  }

  function fmt(t) {
    if (!isFinite(t) || t < 0) t = 0;
    const h = Math.floor(t / 3600), m = Math.floor((t % 3600) / 60), s = Math.floor(t % 60);
    return h
      ? `${h}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`
      : `${m}:${String(s).padStart(2, "0")}`;
  }

  // MSE/DASH streams (Disney+, etc.) often report video.duration as Infinity/NaN;
  // the real length lives in the seekable range — same source the native player
  // uses. Fall back to it so the end time shows.
  function totalDuration() {
    const d = video.duration;
    if (isFinite(d) && d > 0) return d;
    try {
      const s = video.seekable;
      if (s && s.length) return s.end(s.length - 1);
    } catch {}
    return 0;
  }

  // ── enter / exit ───────────────────────────────────────────────────────────
  function enter(id) {
    const v = findVideo(id);
    if (!v) return { ok: false, error: "No video found on this page." };
    if (host) exit();
    video = v;

    host = document.createElement("div");
    host.id = "videopro-focus-host";
    host.style.cssText = "all:initial;position:fixed;inset:0;z-index:2147483647;";
    root = host.attachShadow({ mode: "open" });
    root.innerHTML = TEMPLATE;
    (document.body || document.documentElement).appendChild(host);

    // Move the live element into our stage, remembering where it was.
    restore = {
      parent: v.parentNode,
      next: v.nextSibling,
      style: v.getAttribute("style"),
      controls: v.controls,
    };
    v.controls = false;
    v.setAttribute(
      "style",
      "max-width:100%;max-height:100%;width:auto;height:auto;outline:none;border-radius:12px;background:#000;box-shadow:0 30px 80px rgba(0,0,0,.6);"
    );
    root.getElementById("stage").insertBefore(v, root.getElementById("stagectl"));

    wire();
    document.documentElement.style.overflow = "hidden";
    return { ok: true };
  }

  function exit() {
    if (!host) return;
    cancelAnimationFrame(raf);
    document.removeEventListener("keydown", onKey, true);
    if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
    if (video && restore) {
      video.controls = restore.controls;
      if (restore.style != null) video.setAttribute("style", restore.style);
      else video.removeAttribute("style");
      if (restore.next && restore.next.parentNode === restore.parent) {
        restore.parent.insertBefore(video, restore.next);
      } else {
        restore.parent.appendChild(video);
      }
    }
    host.remove();
    host = root = video = restore = null;
    document.documentElement.style.overflow = "";
  }

  // ── wiring ─────────────────────────────────────────────────────────────────
  function $(id) { return root.getElementById(id); }

  function wire() {
    const playBtn = $("play"), bigPlay = $("bigplay"), seek = $("seek"),
      cur = $("cur"), dur = $("dur"), mute = $("mute"), vol = $("vol"),
      speed = $("speed"), buf = $("buf");

    const syncPlay = () => {
      const playing = !video.paused && !video.ended;
      playBtn.textContent = playing ? "❚❚" : "►";
      bigPlay.style.display = playing ? "none" : "grid";
    };
    const togglePlay = () => (video.paused ? video.play() : video.pause());
    playBtn.onclick = togglePlay;
    bigPlay.onclick = togglePlay;
    $("backdrop").onclick = exit;
    $("close").onclick = exit;

    video.addEventListener("play", syncPlay);
    video.addEventListener("pause", syncPlay);
    video.addEventListener("ended", syncPlay);

    const tick = () => {
      const d = totalDuration();
      if (d) {
        const ct = Math.min(video.currentTime, d);
        seek.value = String((ct / d) * 1000);
        cur.textContent = fmt(video.currentTime);
        dur.textContent = fmt(d);
        try {
          if (video.buffered.length) {
            const end = video.buffered.end(video.buffered.length - 1);
            buf.style.width = `${Math.min(100, (end / d) * 100)}%`;
          }
        } catch {}
      } else {
        dur.textContent = "live";
      }
      raf = requestAnimationFrame(tick);
    };
    tick();

    seek.oninput = () => {
      const d = totalDuration();
      if (d) video.currentTime = (Number(seek.value) / 1000) * d;
    };

    const syncMute = () => (mute.textContent = video.muted || video.volume === 0 ? "🔇" : "🔊");
    mute.onclick = () => { video.muted = !video.muted; syncMute(); };
    vol.value = String(video.volume);
    vol.oninput = () => { video.volume = Number(vol.value); video.muted = video.volume === 0; syncMute(); };
    syncMute();

    speed.value = String(video.playbackRate);
    speed.onchange = () => (video.playbackRate = Number(speed.value));

    $("pip").onclick = async () => {
      try {
        if (document.pictureInPictureElement) await document.exitPictureInPicture();
        else await video.requestPictureInPicture();
      } catch {}
    };
    $("full").onclick = () => {
      if (document.fullscreenElement) document.exitFullscreen();
      else host.requestFullscreen?.().catch(() => {});
    };
    $("send").onclick = sendToApp;

    syncPlay();
    document.addEventListener("keydown", onKey, true);
  }

  function onKey(e) {
    if (!host) return;
    switch (e.key) {
      case "Escape": e.preventDefault(); exit(); break;
      case " ": case "k": e.preventDefault(); video.paused ? video.play() : video.pause(); break;
      case "ArrowRight": e.preventDefault(); video.currentTime += 5; break;
      case "ArrowLeft": e.preventDefault(); video.currentTime -= 5; break;
      case "ArrowUp": e.preventDefault(); video.volume = Math.min(1, video.volume + 0.1); break;
      case "ArrowDown": e.preventDefault(); video.volume = Math.max(0, video.volume - 0.1); break;
      case "f": e.preventDefault(); $("full").click(); break;
      case "m": e.preventDefault(); $("mute").click(); break;
    }
  }

  async function sendToApp() {
    const btn = $("send");
    const src = video.currentSrc || video.src || "";
    const payload = {
      pageUrl: location.href,
      pageTitle: document.title || "",
      videos: [{
        title: document.title || location.hostname,
        pageUrl: location.href,
        pageTitle: document.title || "",
        primarySrc: src.startsWith("http") ? src : "",
        mediaUrl: src.startsWith("http") ? src : "",
        srcKind: src.startsWith("http") ? "file" : "page",
        width: video.videoWidth || 0,
        height: video.videoHeight || 0,
        duration: isFinite(video.duration) ? video.duration : null,
      }],
    };
    btn.textContent = "Sending…";
    try {
      const res = await fetch(`${APP_BASE}/videos`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      });
      const data = await res.json();
      btn.textContent = data.ok ? "✓ Sent" : "Failed";
    } catch {
      btn.textContent = "App offline";
    }
    setTimeout(() => (btn.textContent = "⬇ Send to app"), 1800);
  }

  // ── template ───────────────────────────────────────────────────────────────
  const TEMPLATE = `
  <style>
    :host { all: initial; }
    * { box-sizing: border-box; font-family: -apple-system, system-ui, sans-serif; }
    #backdrop {
      position: fixed; inset: 0;
      background: rgba(6,7,12,.86); backdrop-filter: blur(8px);
    }
    #stage {
      position: fixed; inset: 0; display: flex; flex-direction: column;
      align-items: center; justify-content: center; gap: 14px; padding: 3vmin;
      pointer-events: none;
    }
    #stage > * { pointer-events: auto; }
    #bigplay {
      position: absolute; top: 50%; left: 50%; transform: translate(-50%,-50%);
      width: 84px; height: 84px; border-radius: 50%; display: grid; place-items: center;
      background: rgba(108,92,231,.92); color: #fff; font-size: 30px; cursor: pointer;
      border: none; box-shadow: 0 10px 40px rgba(108,92,231,.5); padding-left: 6px;
    }
    #bar {
      width: min(1000px, 94vw); display: flex; align-items: center; gap: 12px;
      padding: 12px 16px; border-radius: 16px;
      background: rgba(24,25,33,.82); backdrop-filter: blur(20px) saturate(1.4);
      border: 1px solid rgba(255,255,255,.08); color: #e8e9ee;
    }
    button.ctl, select.ctl {
      background: rgba(255,255,255,.08); color: #e8e9ee; border: none;
      border-radius: 10px; height: 34px; min-width: 34px; padding: 0 10px;
      cursor: pointer; font-size: 14px;
    }
    button.ctl:hover { background: rgba(255,255,255,.16); }
    #send { background: linear-gradient(135deg,#6c5ce7,#8b7bff); white-space: nowrap; }
    #seekwrap { position: relative; flex: 1; height: 18px; display: flex; align-items: center; }
    #buf {
      position: absolute; left: 0; top: 7px; height: 4px; border-radius: 3px;
      background: rgba(255,255,255,.22); width: 0;
    }
    input[type=range] {
      -webkit-appearance: none; appearance: none; width: 100%; height: 4px;
      border-radius: 3px; background: rgba(255,255,255,.3); outline: none; position: relative;
    }
    input[type=range]::-webkit-slider-thumb {
      -webkit-appearance: none; width: 14px; height: 14px; border-radius: 50%;
      background: #8b7bff; cursor: pointer; box-shadow: 0 0 8px rgba(139,123,255,.8);
    }
    #vol { width: 80px; }
    #time { font-variant-numeric: tabular-nums; font-size: 12px; color: #b9bcc7; white-space: nowrap; }
    #top { position: fixed; top: 16px; right: 16px; display: flex; gap: 8px; }
    #hint { position: fixed; bottom: 10px; left: 50%; transform: translateX(-50%);
      font-size: 11px; color: rgba(255,255,255,.4); }
  </style>
  <div id="backdrop"></div>
  <div id="stage">
    <button id="bigplay">►</button>
    <div id="stagectl" style="display:contents"></div>
    <div id="bar">
      <button class="ctl" id="play">►</button>
      <span id="time"><span id="cur">0:00</span> / <span id="dur">0:00</span></span>
      <div id="seekwrap"><div id="buf"></div><input id="seek" type="range" min="0" max="1000" value="0"></div>
      <button class="ctl" id="mute">🔊</button>
      <input class="ctl" id="vol" type="range" min="0" max="1" step="0.05" style="padding:0">
      <select class="ctl" id="speed" title="Speed">
        <option value="0.5">0.5×</option><option value="0.75">0.75×</option>
        <option value="1" selected>1×</option><option value="1.25">1.25×</option>
        <option value="1.5">1.5×</option><option value="2">2×</option>
      </select>
      <button class="ctl" id="pip" title="Picture in Picture">⧉</button>
      <button class="ctl" id="full" title="Fullscreen">⛶</button>
      <button class="ctl" id="send">⬇ Send to app</button>
    </div>
  </div>
  <div id="top"><button class="ctl" id="close" title="Close (Esc)">✕</button></div>
  <div id="hint">space play · ← → seek · f fullscreen · esc close</div>
  `;

  if (typeof chrome !== "undefined" && chrome.runtime?.onMessage) {
    chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
      if (msg?.type === "VIDEOPRO_FOCUS") { sendResponse(enter(msg.videoId)); return; }
      if (msg?.type === "VIDEOPRO_UNFOCUS") { exit(); sendResponse({ ok: true }); return; }
    });
  } else {
    // Running outside the extension (e.g. a test harness) — expose the API.
    window.__videoproFocusTest = { enter, exit };
  }
})();

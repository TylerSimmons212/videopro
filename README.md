# VideoPro

Find videos in your browser, then **play or download** them with the full power of
[yt-dlp](https://github.com/yt-dlp/yt-dlp) + ffmpeg — from a native macOS app.

VideoPro is two pieces that talk over a tiny loopback bridge:

```
┌─ Chrome: lite extension ──────────┐        ┌─ VideoProApp (native SwiftUI) ──────────┐
│ • detects videos on any page      │        │ • local HTTP server ← 127.0.0.1:8787    │
│ • pop-out focus player (⌘⇧Y)      │        │ • download queue (yt-dlp + ffmpeg)      │
│ • "Send to VideoPro" ─────────────┼─POST──▶│ • play (AVKit) · thumbnails · convert   │
│ • real DRM (EME) detection        │  JSON  │ • paste-a-URL · notifications · badge   │
└───────────────────────────────────┘        └─────────────────────────────────────────┘
```

A native app can bundle and run yt-dlp/ffmpeg directly — real muxed 1080p/4K, every
site yt-dlp supports, no browser-store policy risk — while the extension keeps the one
thing only a browser can do: see the video playing on the current page.

## Features

**Mac app**
- Receives videos from the extension over a loopback HTTP bridge
- **Download queue** with a concurrency limit; **persistent history** (survives relaunch)
- **Quality picker** per video (Best · MP4/H.264 · 2160–480p · Audio-only), probed live
- Embeds **thumbnail + subtitles + metadata**; prefers H.264/AAC for universal playback
- **Play** in-app (AVKit); auto-generated preview frames for videos without a thumbnail
- **Convert / trim** finished downloads → MP4 clip · GIF · MP3 (ffmpeg)
- **Paste a URL** to grab a video without the extension
- Completion **notifications** + Dock badge; **Liquid Glass** UI (macOS 26+)
- First-launch **onboarding** that installs the extension for you

**Extension**
- Detects `<video>` elements + sniffs HLS/DASH/direct media (collapses adaptive variants)
- **Pop-out focus player**: theater view with custom controls (scrub, speed, PiP, fullscreen)
- **Real DRM detection** via EME (`encrypted` event / `mediaKeys`) — no domain guessing
- Toolbar **badge** with the video count; **⌘⇧Y** hotkey to pop out the active video
- **Auto-launches the app** (via `videopro://`) if it isn't running when you Send
- Remembers what you've already sent

## Repository layout

```
VideoProApp/            # native macOS app (Xcode, SwiftUI)
  VideoProApp/
    VideoProAppApp.swift   # @main, URL-scheme handling
    AppState.swift         # queue, persistence, convert, extension install
    LocalServer.swift      # loopback HTTP bridge (Network.framework)
    DownloadManager.swift  # yt-dlp/ffmpeg jobs
    Models.swift           # VideoMeta / VideoItem, quality & export enums
    ContentView.swift      # UI, onboarding, export & quality sheets
    AppIcon.icon           # Icon Composer (Liquid Glass) app icon
    Info.plist             # registers the videopro:// URL scheme

extension/              # lite Chrome extension (load this folder unpacked)
  manifest.json  content.js  focus.js  background.js  popup.{html,css,js}

scripts/
  fetch-binaries.sh    # download yt-dlp + static ffmpeg for bundling
  bundle-extension.sh  # zip extension/ into the app's Resources
  package-app.sh       # build a self-contained VideoPro.app + DMG
```

## Run it (development)

**App** — needs `yt-dlp` and `ffmpeg`:
```bash
brew install yt-dlp ffmpeg     # or bundle them (see Distribution)
open VideoProApp/VideoProApp.xcodeproj   # then ⌘R
```

**Chrome extension** — `chrome://extensions` → Developer mode → **Load unpacked** →
select `extension/`. (Or launch the app and use its onboarding / **Settings → Get
the extension…**.)

**Safari extension** — the app bundles a Safari Web Extension (`VideoProApp/safari/`,
same code as the Chrome one). Build/run the app, then enable it in **Safari → Settings
→ Extensions**. After editing `extension/`, run `bash scripts/sync-safari.sh` to keep
them in sync, then rebuild.

Open a page with a video → click a card to pop it out, or **Send** it to the app.

## Distribution (self-contained)

```bash
bash scripts/package-app.sh
```
Downloads the **official yt-dlp** + a **static, arch-matched ffmpeg**, builds the Release
app with them embedded in `Contents/Resources/bin/`, ad-hoc signs it, and produces
`dist/VideoPro.dmg` — which runs on any Mac **without Homebrew**.

For frictionless distribution to anyone, notarize with your **Apple Developer ID**:
```bash
# one-time: store a fresh app-specific password (you run this, so you type it)
xcrun notarytool store-credentials VIDEOPRO \
  --apple-id "<you@example.com>" --team-id "<TEAMID>" --password "<app-specific-pw>"

bash scripts/notarize.sh   # signs (hardened runtime + entitlements), submits, staples
```
Until notarized, recipients right-click → **Open** once to bypass Gatekeeper's
"unidentified developer" prompt.

## Limitations

- **DRM** (Disney+, Netflix, etc.) can't be downloaded by anything — the decrypted
  stream lives in a protected buffer. VideoPro flags these `🔒 DRM`; pop-out still works
  for viewing.
- Trim uses stream-copy (instant, snaps to keyframes). Convert re-encodes.

## License / ethics

Use only for content you're allowed to download. Respect site terms and copyright.

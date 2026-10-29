# VideoPro

Download video and audio from the web with the full power of
[yt-dlp](https://github.com/yt-dlp/yt-dlp) + ffmpeg — then clip, convert or join it —
from a native macOS app.

```
┌─ VideoProApp (native SwiftUI) ───────────────────────────────────────────┐
│  one field: paste a link → see what's there → download                   │
│  ⌃⌥⌘D / menu bar: grab the video in your browser's front tab             │
│  bookmarklet: send the page you're on, from any browser                  │
│                                                                          │
│  download queue (yt-dlp) · pause/resume · library · editor (ffmpeg)      │
└──────────────────────────────────────────────────────────────────────────┘
```

## Features

**Getting videos in**
- **One field for links and searches.** Paste a link and it shows what's there before
  anything downloads: a single video with every quality and its size, or every video
  on a playlist, channel or page in a grid — pick some or all, choose a quality, and
  download them together. Anything that isn't a link searches your library.
- **Copied links wait for you** — come back to VideoPro and a link you copied elsewhere
  is already in the field (Settings → General). **⇧⌘V** downloads it without looking.
- **Global shortcut (⌃⌥⌘D)** and **menu bar** grab the video in the browser tab you
  were last in (Safari, Chrome, Arc, Brave, Edge, Vivaldi, Opera).
- **Bookmarklet** for any browser, Firefox included (Settings → Quick Grab). Only your
  own bookmarklet can start a download; any other `videopro://` link just fills the field.
- **Sign-in cookies** (opt-in) for private, members-only and age-restricted videos.

**Downloading**
- **Pause and resume**, per download or all at once (⌥⌘P / ⌥⌘R). Quitting stops
  downloads where they are; they carry on at the next launch.
- **Download queue** with a concurrency limit and an Activity popover (cancel, history).
- **Quality picker** per video, probed live; prefers H.264/AAC for universal playback.
- **Plays in QuickTime.** Above 1080p YouTube sends AV1 or VP9, which QuickTime can't
  play on Macs before M3; such downloads are re-encoded to HEVC on the hardware encoder
  (Settings → Downloads). The picker says up front when a quality needs it.
- Embeds **thumbnail + subtitles + metadata**. The Mac stays awake while downloading.

**Library and editing**
- **Inbox** that tidies itself, **Collections** for what you keep, search, sort,
  multi-select and batch actions.
- **Your own files** — drag them in, referenced in place. Media inspector via ffprobe.
- **Editor**: timeline with in/out handles, crop, rotate, speed, mirror, mute, kept as a
  recipe; export presets (MP4, 1080p, 720p, Reel 9:16, GIF, MP3, ProRes, "under N MB").
- **Join a collection** into one video.

## Repository layout

```
VideoProApp/            # native macOS app (Xcode, SwiftUI)
  VideoProApp/
    VideoProAppApp.swift   # @main, menus, videopro:// handling
    AppState.swift         # library, queue, pause/resume, persistence
    LinkProbe.swift        # what's behind a link (yt-dlp -J --flat-playlist)
    LinkSearch.swift       # the link/search field's state
    LinkResultsView.swift  # single-video card and the selection grid
    DownloadManager.swift  # yt-dlp/ffmpeg jobs
    Models.swift           # VideoMeta / VideoItem, quality & export enums
    ContentView.swift      # library UI, onboarding
    AppIcon.icon           # Icon Composer (Liquid Glass) app icon
    Info.plist             # registers the videopro:// URL scheme

scripts/
  fetch-binaries.sh    # download yt-dlp + static ffmpeg for bundling
  package-app.sh       # build a self-contained VideoPro.app + DMG
```

## Run it (development)

Needs `yt-dlp`, `ffmpeg` and `deno` (yt-dlp's JavaScript runtime for YouTube), and
yt-dlp has to be **current** — YouTube refuses downloads from versions a few months
old (HTTP 403). Homebrew's yt-dlp brings Deno with it:
```bash
brew install yt-dlp ffmpeg     # or: bash scripts/fetch-binaries.sh (the pinned set)
brew upgrade yt-dlp            # whenever YouTube downloads start failing
open VideoProApp/VideoProApp.xcodeproj   # then ⌘R
```

## Distribution (self-contained)

```bash
bash scripts/package-app.sh
```
Downloads the **official yt-dlp**, a **static, arch-matched ffmpeg/ffprobe** and **Deno**
(so yt-dlp can solve YouTube's JavaScript challenges and see every format), builds the
Release app with them embedded in `Contents/Resources/bin/`, ad-hoc signs it, and
produces `dist/VideoPro.dmg` — which runs on any Mac **without Homebrew**.

The tools are **pinned**: `scripts/binaries.lock` holds each file's URL and SHA-256,
and the build refuses anything that doesn't match. Bump the pins before every release
— yt-dlp above all — and commit the lock:
```bash
bash scripts/pin-binaries.sh   # latest releases, each checked against its publisher's checksum
```
`package-app.sh` warns once the pinned yt-dlp is more than 60 days old.

For frictionless distribution to anyone, notarize with your **Apple Developer ID**:
```bash
# one-time: store a fresh app-specific password (you run this, so you type it)
xcrun notarytool store-credentials VIDEOPRO \
  --apple-id "<you@example.com>" --team-id "<TEAMID>" --password "<app-specific-pw>"

bash scripts/notarize.sh   # signs (hardened runtime + entitlements), submits, staples
```
Deno is signed with its own entitlements (`scripts/deno-entitlements.plist`): its
JavaScript engine needs JIT, which the hardened runtime otherwise refuses.
Until notarized, recipients right-click → **Open** once to bypass Gatekeeper's
"unidentified developer" prompt.

## Limitations

- **DRM** (Disney+, Netflix, etc.) can't be downloaded by anything — the decrypted
  stream lives in a protected buffer. VideoPro says so rather than failing quietly.
- **Pages yt-dlp can't read** have no fallback since the browser extension was removed;
  a built-in browser that picks up what a page plays is planned.
- Trim uses stream-copy (instant, snaps to keyframes). Convert re-encodes.
- Exporting a video you haven't downloaded has to fetch its source first — only
  the requested section for a clip/GIF, audio-only for MP3. Exports from an
  already-downloaded file skip the network entirely.

## License / ethics

Use only for content you're allowed to download. Respect site terms and copyright.

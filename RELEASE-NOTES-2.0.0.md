# VideoPro 2.0.0

VideoPro is now an app first. The browser extension still works, but it's
optional — everything it did, the app now does on its own.

## Grab a video without opening the window

- **Global shortcut (⌃⌥⌘D)** — press it anywhere and VideoPro downloads whatever
  is playing in the browser you were last in. Customisable in Settings.
- **Menu bar item** for the same thing with one click, plus paste-and-download.
- **Sign-in cookies** (opt-in) so private, members-only and age-restricted videos
  work without the extension.

## A library that tidies itself

- **Inbox** — new videos land here and clear themselves after a while. Your files
  are never touched, only the list entry. No more clearing out one-off grabs.
- **Collections** — anything you act on is kept automatically. Group videos,
  reorder them, and join a whole collection into one video.
- **Search, sort, multi-select** and batch actions across the library.
- Sidebar now holds places rather than status filters; status became chips, and
  in-progress work moved to an Activity popover with cancel, retry and history.

## Your own files

- **Drag videos in**, or import them — referenced where they sit, never copied.
- **Media inspector** showing codec, bitrate, frame rate and every audio and
  subtitle track.
- Editing no longer requires downloading first.

## A real editor

- **Timeline** with draggable in/out handles, live preview, frame stepping and
  loop-the-selection — replacing two text fields you typed times into blind.
- **Crop, rotate, speed, mirror and mute**, kept as a recipe rather than applied,
  so your edit survives and can be re-exported.
- **Export presets**: MP4, 1080p, 720p, Reel/Short (9:16), GIF, MP3, ProRes, and
  "under N MB" via a real two-pass encode.
- **Chapters** from the source are marked on the timeline.
- GIFs use a proper generated palette and look markedly better.

## Fixes

- **Downloads no longer stop after a while.** A stalled transfer used to hold its
  slot forever and three of them wedged the queue for the session. Transfers are
  now watched and released, and the queue can't be stranded by one stuck job.
- **Exports can be cancelled and retried**, and no longer hang on long jobs.
- **YouTube subtitles work again.** The language pattern was matching YouTube's
  translated auto-captions, which triggered rate limiting and aborted the whole
  download — video included.
- Downloads that needed merging no longer lose track of the finished file.
- Broken thumbnails no longer render as a thin coloured bar.
- Download preferences now persist between launches.
- Player opens in its own window instead of blocking the app.
- Settings is a proper window (⌘,) instead of a cramped popover.

## Privacy

VideoPro no longer listens on a local port unless you turn the browser extension
on. If you already use the extension, nothing changes.

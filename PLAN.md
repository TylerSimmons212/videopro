# VideoPro — app-first rework

## Direction

Move the centre of gravity off the browser extension and onto the app. The
extension stays available for awkward sites, but it stops being infrastructure:
no onboarding gate, no sidebar real estate, no setup flow standing between a new
user and their first download.

## The two modes

The same person uses this app two ways, often on different days:

- **One-off** — "I want *this* video." Wants speed and zero ceremony. Every
  organisational concept is friction.
- **Collector** — "I'm gathering videos to do something with." Wants
  organisation, batch operations, and an editor.

These are modes, not audiences. Do not make people declare which one they are.

**Design rule: collector features must be invisible until invoked.** No empty
Collections ceremony on first launch, no forced tagging, no organisational
onboarding. A first-time user should be downloading within a few seconds of
launch and never meet a single organising concept unless they ask for one.

## Library model: ephemeral by default, promotion by action

Today everything that arrives is persisted forever. That's the collector's model
imposed on everyone — and the "Clear all" button in the toolbar is the tell: it
only exists because accumulated clutter is a real problem.

Two tiers instead:

- **Inbox** — everything lands here. Entries age out of the library view after N
  days. **The file on disk is never touched**; only the library entry expires.
  The one-off user never cleans up and never sees clutter.
- **Collections** — durable and user-owned. An item is *promoted* automatically
  the moment the user does something implying intent: tag it, add it to a
  collection, edit it, or rename it. Project work produces the promotion gesture
  as a byproduct, so neither mode has to think about tiers.

Inbox and Collections are genuinely different *scopes*. The current sidebar
sections (All / Downloading / Completed / Failed) are one list with a `where`
clause, which is why they feel redundant — status moves to filter chips above
the list, and in-flight work moves to an Activity popover in the toolbar.

## Data model changes

```
VideoMeta
  + tier: .inbox | .collection      // promotion state
  + addedAt / lastTouchedAt         // drives Inbox expiry
  + tags: [String]
  + collectionIDs: [UUID]
  + localOnly: Bool                 // imported file, no remote source
  + edit: EditRecipe?               // non-destructive, re-exportable
  + probe: MediaInfo?               // from ffprobe (codec, bitrate, fps, tracks)

Collection { id, name, ordering: [UUID], exportSettings }
EditRecipe { inPoint, outPoint, crop, rotate, speed, scale }
Job { id, kind: .download|.export|.probe, progress, state, retry }
```

`downloadURL` can no longer be assumed non-empty — imported local files have no
remote source. Every path that reads it needs an audit.

---

## Milestones

### M1 — Fast path (front-tab capture, menu bar, hotkey)

The smallest slice that proves the pivot, and independently shippable.

- `FrontTab` — read the active tab's URL from the browser the user was last in,
  via AppleScript. Two dialects: Safari (`current tab` / `name`), Chromium and
  Arc (`active tab` / `title`). Bounded with `with timeout of 2 seconds`.
- Track the last-active browser via `NSWorkspace.didActivateApplicationNotification` —
  when triggered from the menu bar or a hotkey *we* are frontmost, so
  "frontmost right now" is the wrong question.
- `NSAppleEventsUsageDescription` in Info.plist (mandatory — without it macOS
  denies outright rather than prompting). Handle `errAEEventNotPermitted (-1743)`
  with a route into System Settings.
- `MenuBarExtra`: Grab Front Tab, paste URL, recent items, open library.
- Global hotkey via Carbon `RegisterEventHotKey` (needs no permission, unlike
  `NSEvent` global monitors which require Accessibility).
- `--cookies-from-browser` so logged-in content works without the extension.

**Outcome:** hotkey → front tab URL → downloading. No window, no paste, no
extension. Firefox is the known gap (no AppleScript dictionary; needs AX).

### M2 — Navigation restructure

- Sidebar becomes Inbox / Recently Added / Collections / Smart Collections /
  Local Files. Collections section stays hidden until one exists.
- Status → filter chips; in-flight work → Activity popover.
- Search, sort, multi-select, batch actions.
- Inbox expiry (library entry only) retires the "Clear all" button.
- Demote extension setup out of onboarding into Settings.

### M3 — Local files + inspector

- Drag & drop, Add Files…, optional watch folder.
- Wire up **ffprobe — already bundled and currently never called** — for
  duration, codec, bitrate, fps, and track listing.
- Media inspector pane. Fixes thumbnails for local files for free.

### M4 — Job system

- One `Job` model covering downloads, exports, and probes: progress, cancel,
  retry, history, concurrency control.
- Replaces the ad-hoc `activeDownloads` counter and the fire-and-forget export
  spinner. Structurally retires the class of bug behind the queue wedge.

### M5 — Single-clip editor

- Timeline scrubber with in/out handles, live preview, frame stepping,
  loop-the-selection. Replaces blind text-field time entry.
- Crop, rotate, speed, scale, frame grab.
- Size-targeted export ("fit under 10MB") via two-pass bitrate calculation.
- Export presets (Reel 9:16, 720p, ProRes, iPhone).
- Chapters from yt-dlp `-J`: jump to them, export one as a clip, split by chapter.
- Non-destructive: the `EditRecipe` persists and re-exports to multiple targets.

### M6 — Collection builder

**The Collection is the sequence** — no separate document model needed.

- Render each clip through its own `EditRecipe` → normalise to a shared target →
  concatenate.
- Constraint: ffmpeg's fast concat path needs identical codec parameters, so
  mixed sources must be normalised first. That's just the M5 export pipeline run
  per clip, which is why this composes rather than becoming an NLE.

---

## Folded-in debt

From the audit, fixed opportunistically inside the milestone that touches it:

- Download preferences are never persisted (M2 — settings rework).
- Generated thumbnails in Application Support are never cleaned up (M2 — expiry).
- `unpackExtension()` deletes the folder Chromium is actively loading from (M1 —
  extension demotion).
- `moveToApplications` destroys an existing install before the copy succeeds (M1).
- Loopback server accepts any origin (`Access-Control-Allow-Origin: *`, no Host
  check) and auto-spawns yt-dlp against attacker-supplied URLs (M1 — token +
  origin allowlist, or removed with the extension).
- Sidebar/list filters observe `AppState` but read `VideoItem` state (M2).

## Non-goals

- Multi-clip NLE (transitions, overlays, multi-track). M6 is concatenation.
- Recording via ScreenCaptureKit or audio taps — that's capture, not download.
- Network-level interception. Needs an Apple entitlement plus a user-installed
  root CA; a non-starter for a consumer app.
- Now Playing / MediaRemote as a *source*. It carries title, artist, artwork and
  elapsed time — never a URL. Useful only as a secondary "something is playing
  in $APP" signal.

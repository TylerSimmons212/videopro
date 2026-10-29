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

As built (M1–M3 shipped; M4–M6 still projected):

```
VideoMeta                           // SHIPPED
  + tier: .inbox | .kept            // promotion state
  + tags: [String]
  + collectionIDs: [UUID]
  + importedPath: String?           // imported file, no remote source
  + probe: MediaInfo?               // ffprobe: codec, bitrate, fps, tracks
    receivedAt                      // already existed; drives Inbox expiry
  + isLocal / filePath              // computed; branch on these, not downloadURL

VideoCollection { id, name, ordering: [UUID], createdAt }   // SHIPPED
KeyCombo { keyCode, modifiers }                             // SHIPPED

Job { id, itemID, title, kind, state, progress, detail }    // M4
EditRecipe { inPoint, outPoint, crop, rotate, speed, scale } // M5
```

Two notes for anyone extending this:

`downloadURL` can no longer be assumed non-empty — an imported file has no remote
source. Branch on `isLocal`, not on `downloadURL.isEmpty`, which is *also* true
for a malformed remote item.

Every new persisted field needs `decodeIfPresent` in `VideoMeta.init(from:)`.
Swift's synthesised `Decodable` throws on a missing key even when the property has
a default, so forgetting this makes older libraries fail to load — and a failed
load used to silently overwrite the file with `[]`.

---

## Milestones

### M1 — Fast path (front-tab capture, menu bar, hotkey) — **DONE**

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

Shipped as described. The global shortcut ended up user-configurable (⌃⌥⌘D by
default) with conflict reporting, since `RegisterEventHotKey` fails silently when
another app already owns a combination.

### M2 — Navigation restructure — **DONE**

- Sidebar becomes Inbox / Recently Added / Collections / Smart Collections /
  Local Files. Collections section stays hidden until one exists.
- Status → filter chips; in-flight work → Activity popover.
- Search, sort, multi-select, batch actions.
- Inbox expiry (library entry only) retires the "Clear all" button.
- Demote extension setup out of onboarding into Settings.

Also landed here: multi-select and batch actions, Settings as a real ⌘, window
(the popover was cramming seven groups into 320pt), playback moved out of its
blocking modal sheet into its own window, and the purple accent replaced by the
system accent throughout. The onboarding backdrop is achromatic now — the old one
was hardcoded dark with no light variant, so it rendered as a dark slab in a light
window and degraded `.regularMaterial` cards into grey bricks.

### M3 — Local files + inspector — **DONE**

- Drag & drop, Add Files…, optional watch folder.
- Wire up **ffprobe — already bundled and currently never called** — for
  duration, codec, bitrate, fps, and track listing.
- Media inspector pane. Fixes thumbnails for local files for free.

Imported files are referenced in place, never copied, and arrive `.kept` since
importing is explicit. `VideoMeta.importedPath` broke the old invariant that every
item has a remote source — `isLocal`/`filePath` exist to branch on rather than
testing `downloadURL` for emptiness, which is also true of a malformed remote item.

### M4 — Job system — **DONE**

- One `Job` model covering downloads, exports, and probes: progress, cancel,
  retry, history, concurrency control.
- Replaces the ad-hoc `activeDownloads` counter and the fire-and-forget export
  spinner. Structurally retires the class of bug behind the queue wedge.

### M5 — Single-clip editor — **DONE**

- Timeline scrubber with in/out handles, live preview, frame stepping,
  loop-the-selection. Replaces blind text-field time entry.
- Crop, rotate, speed, scale, frame grab.
- Size-targeted export ("fit under 10MB") via two-pass bitrate calculation.
- Export presets (Reel 9:16, 720p, ProRes, iPhone).
- Chapters from yt-dlp `-J`: jump to them, export one as a clip, split by chapter.
- Non-destructive: the `EditRecipe` persists and re-exports to multiple targets.

Landed as described. Two findings worth keeping: `setpts` alone produces a
stuttering low-frame-rate file when slowing down (nothing fills the stretched
gaps, so 0.25× measured 7.5 fps) — an `fps` filter has to close it. And target
framing must come *after* rotation, or rotating a 1080x1920 Reel frame yields
1920x1080 and silently breaks the 9:16 guarantee.

### M6 — Collection builder — **DONE**

**The Collection is the sequence** — no separate document model needed.

- Render each clip through its own `EditRecipe` → normalise to a shared target →
  concatenate.
- Constraint: ffmpeg's fast concat path needs identical codec parameters, so
  mixed sources must be normalised first. That's just the M5 export pipeline run
  per clip, which is why this composes rather than becoming an NLE.

Normalisation turned out to be the whole job, and the trap is a clip with **no
audio track at all**: `-an` leaves a hole with no decodable samples, so every
segment gets an audio track, synthesising `anullsrc` silence at the spec's layout
when the source has none. Muting substitutes silence rather than dropping the
track, for the same reason. Joins are letterboxed rather than cover-cropped — a
collection is exactly where aspect ratios differ, and lost framing can't be undone.

### M7 — On-device clip suggestions — **REMOVED**

Built and then taken out before release. It worked — query-driven search returned
correct cue ranges and declined to invent clips for content that wasn't there —
but it wasn't earning its place: it needs subtitles, needs Apple Intelligence
enabled, and takes seconds per search to answer a question you can usually answer
by scrubbing. Recoverable from git history if it's ever worth revisiting.

Two things from it were kept, because they were real bugs rather than feature code:
the `--sub-langs` fix (see debt list) and the paced subtitle requests.

### M8 — Link field, pause/resume, extension removed — **DONE**

Downloader parity with Downbit, built on yt-dlp rather than a rewrite.

- **One field for links and searches.** `yt-dlp -J --flat-playlist` says what a link
  is in a second or two: one video (with each quality's real resolution, codec and
  size) or a list. Lists show as a grid to pick from; channels come back as their
  tabs (Videos, Live, Shorts); "Load More" pages through with `--playlist-items`.
  Not-a-link text searches the library.
- **Copied links** are offered on activation. The pasteboard's pattern detection is
  checked first, so the paste-privacy prompt can only appear when there's a link.
- **Pause/resume** by running the same yt-dlp command again over its `.part` files.
  `--no-part` had to go — with it a stopped download left a truncated file under the
  final name that the next attempt took as finished. Quitting suspends downloads and
  the next launch resumes them; cancel deletes the partials.
- **The browser extension, its Safari target and the loopback server are gone.** The
  link field, the front-tab shortcut and a bookmarklet (`videopro://download`, gated
  by a per-install secret) cover what it did. The one thing lost is a fallback for
  pages yt-dlp can't read — a built-in browser is the replacement.

Findings worth keeping: the capped presets prefer H.264 over resolution, so on YouTube
"2160p (4K)" yields 1080p; the link field labels each choice with what it really gets,
but the old quality menu still says 2160p. And a format with no codec listed (any
direct file link) means *unknown*, not *none* — treating it as none made a plain MP4
look audio-only.

### Next

- Built-in browser (WKWebView) that lists the media a page plays, for pages yt-dlp
  can't read; its sign-ins exported as a cookie file for `--cookies`.
- Playlist options beyond the grid: subscriptions (`--download-archive`), live
  recording, SponsorBlock, more formats, file-name templates.
- Bundle a JavaScript runtime (Deno) for yt-dlp's YouTube challenge solving.
- Pin yt-dlp/ffmpeg downloads to checksums in `fetch-binaries.sh`.

---

## Folded-in debt

Fixed:

- The loopback server accepted any origin and let any page start yt-dlp — removed
  with the extension. Every yt-dlp call now passes the address after `--`.
- `unpackExtension()` deleted the folder Chromium was loading from — removed.
- `start()` ran again whenever a closed window reopened, reloading the library over
  live downloads. It now runs once.
- Removing an item mid-download left yt-dlp running; it now stops it.
- ⌘A shadowed select-all in the search field; it now stands aside while the field has focus.

- Download preferences were never persisted — reset on every launch.
- Generated thumbnails were never cleaned up; `remove()` now prunes them.
- Sidebar/list filters observed `AppState` but read `VideoItem` state, so counts
  went stale. `VideoItem.statusChanged` is re-published throttled.
- A library decode failure was indistinguishable from an empty library, and the
  next save overwrote the file with `[]`. It now backs up and refuses to write.
- Subprocess handling: unbounded blocking probes exhausting the dispatch thread
  pool, an undrained ffmpeg stderr deadlocking exports, a lost race on yt-dlp's
  final "Merging formats into" line, and a truncated JPEG rendering as a thin bar
  because `NSImage(data:)` returns a usable object for a partial decode.

Still outstanding:

- `moveToApplications` destroys an existing install before the copy succeeds.
- `toolSummary` never mentions ffprobe, so a missing one is unexplained.

## Non-goals

- Multi-clip NLE (transitions, overlays, multi-track). M6 is concatenation.
- Recording via ScreenCaptureKit or audio taps — that's capture, not download.
- Network-level interception. Needs an Apple entitlement plus a user-installed
  root CA; a non-starter for a consumer app.
- Now Playing / MediaRemote as a *source*. It carries title, artist, artwork and
  elapsed time — never a URL. Useful only as a secondary "something is playing
  in $APP" signal.

# VideoPro 2.0.1

## Fixes the browser grab when VideoPro is run from the disk image

If you opened VideoPro straight from the downloaded disk image, macOS was running
it from a temporary copy. That stopped it from asking permission to read your
browser's current tab — and because macOS only lists apps that have already
asked, VideoPro never appeared under Privacy & Security → Automation, so there
was no switch to turn on.

- VideoPro now notices this at launch and offers to move itself to Applications,
  which is what makes the permission prompt work.
- If permission was already refused, the message now offers to ask again rather
  than pointing at a setting that may not exist yet.

Nothing else has changed from 2.0.0.

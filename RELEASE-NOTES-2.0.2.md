# VideoPro 2.0.2

## The browser grab now works in released builds

Grabbing the video from your browser's front tab never worked in 2.0.0 or 2.0.1.
Released builds were missing the permission they need to talk to your browser at
all, so macOS refused the request before it could even ask you — which is why
VideoPro never appeared under Privacy & Security → Automation and there was no
switch to turn on.

After updating, use the menu bar item or the shortcut once and macOS will ask for
permission properly. Say yes and it will work from then on.

## Also

- The app icon is back.

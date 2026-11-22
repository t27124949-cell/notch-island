# Notch Island v1.1

Turn the MacBook notch into an interactive island. Hover to open a tabbed panel; it also shows live music and battery info while closed.

## What's new
- Closed notch shows an animated equalizer while music plays, or your battery level when idle, without changing its size
- Live previews for song changes, charging, low battery and finished timers
- Tap the now-playing artwork or title to open the song in Spotify or Apple Music, or the artist/album to search for it
- Song lyrics (LRCLIB, lyrics.ovh, optional Musixmatch key), can be turned off in Settings
- Focus switching from Quick Controls (needs a one-time Shortcuts setup, see README)
- Clipboard history with search and pinned items, saved between launches, clearable any time
- Island height now fits each tab, so no empty space
- **Open at login** switch in Settings
- New app icon

## Install
1. Download `NotchIsland.zip` below and unzip it.
2. Drag `NotchIsland.app` into **Applications**.
3. Open it. macOS will block it the first time because it isn't notarized: go to **System Settings → Privacy & Security** and click **Open Anyway**.
4. Allow the Calendar and Music/Spotify prompts if you use those tabs.

Requires macOS 13 or later. Built for MacBooks with a notch.

## Notes
- Everything runs locally. Network requests: weather (Open-Meteo) and lyrics lookups only. See the README's Privacy section.
- Clipboard history is stored as plain text on your Mac. You can turn this off in Settings.
- Found a bug? Open an issue and include Menu bar icon → Debug Info.

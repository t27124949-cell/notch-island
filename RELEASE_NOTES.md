# Notch Island v1.3

## What's new (since v1.1)
- **Coding agent approvals**: approve or deny Claude Code and Codex permission requests from the notch, without switching windows. Connect from the new Coding Agents tab. If the app isn't running, your agent asks you as usual.
- **New music player**: bigger artwork, player badge, progress bar with times, volume slider and a sound output picker (speakers, AirPods and other Bluetooth)
- **Tap to sync lyrics**: for songs with no timing, tap as each line starts. Your timing is saved on your Mac and used next time
- **Lyrics**: animated synced lyrics, estimated scrolling for untimed lyrics, and a timing nudge in Settings
- **Month calendar**: click a day to see its events, with a Join button for Zoom, Meet, Teams, Webex, Whereby and Jitsi. Five minutes before a call, the notch tells you and opens on the Calendar tab
- **Swipe gestures**: two-finger swipes switch tabs, change songs, pin or close the island. Each direction is set in Settings
- **Shelf**: click files to select them, picture thumbnails, and AirDrop the selected files
- **AirPods and Bluetooth alerts** with battery levels
- **Battery time remaining** on Home
- **Timer sound** when the timer finishes (choose or turn off)
- **Glass look** slider, from solid black to frosted glass
- **Check for updates** and **Report a bug** buttons
- First-run welcome that explains the permissions
- A pinned island stays open when you click outside, and the island is a bit narrower
- **DMG installer**: drag Notch Island onto Applications

## Install
1. Download `NotchIsland.dmg` (or `NotchIsland.zip`) below.
2. Drag `NotchIsland.app` into **Applications** (replace the old one).
3. Open it. If macOS blocks it, go to **System Settings → Privacy & Security** and click **Open Anyway**.

Requires macOS 13 or later. Built for MacBooks with a notch.

## Notes
- Everything runs locally. Network requests: weather, lyrics lookups and the update check only.
- Agent approvals use a local-only connection on your Mac (127.0.0.1) with a secret token, and never auto-approve.
- Found a bug? Use Settings → Report a bug.

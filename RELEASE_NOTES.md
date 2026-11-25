# Notch Island v1.4

## What's new
- **Sound output picker**: switch between your speakers, AirPods and other outputs from the Music tab (the AirPlay icon next to the volume slider)
- **Meeting banner**: five minutes before a call with a link, the notch announces it, and opening the island lands on the Calendar tab with the green Join button
- **Jitsi links** now work with Join, alongside Zoom, Meet, Teams, Webex and Whereby
- **Better bug reports**: the report button now includes your Mac model
- **DMG installer**: drag Notch Island onto Applications

## Earlier in v1.3
Coding agent approvals (Claude Code and Codex), tap-to-sync lyrics, month calendar, swipe gestures, shelf with AirDrop, AirPods alerts, battery time remaining, timer sound, glass look, check for updates.

## Install
1. Download `NotchIsland.dmg` (or `NotchIsland.zip`) below.
2. Drag `NotchIsland.app` into **Applications** (replace the old one).
3. Open it. If macOS blocks it, go to **System Settings → Privacy & Security** and click **Open Anyway**.

Requires macOS 13 or later. Built for MacBooks with a notch.

## Notes
- Everything runs locally. Network requests: weather, lyrics lookups and the update check only.
- Agent approvals use a local-only connection on your Mac (127.0.0.1) with a secret token, and never auto-approve.
- Found a bug? Use Settings → Report a bug.

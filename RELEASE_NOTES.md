# Notch Island v1.2

## What's new
- **Coding agent approvals**: approve or deny Claude Code and Codex permission requests right from the notch, without switching windows. Connect from the new Coding Agents tab. If the app isn't running, your agent asks you as usual.
- **New music player**: bigger artwork, player app badge, thick progress bar, elapsed and total time
- **Month calendar**: click any day to see its events; Join button for Zoom, Meet and Teams links
- **Check for updates** button in Settings and the menu bar
- **Synced lyrics animation**, and gentle estimated scrolling for lyrics that have no timing
- **Glass look** slider in Settings (solid black to frosted glass)
- **Timer sound**: a chime when the timer finishes, or turn it off
- A pinned island now stays open when you click outside
- Slightly narrower island, tab icons shrink to fit

## Install
1. Download `NotchIsland.zip` below and unzip it.
2. Drag `NotchIsland.app` into **Applications** (replace the old one).
3. Open it. If macOS blocks it, go to **System Settings → Privacy & Security** and click **Open Anyway**.

Requires macOS 13 or later. Built for MacBooks with a notch.

## Notes
- Everything runs locally. Network requests: weather, lyrics lookups and the update check only.
- Agent approvals use a local-only connection on your Mac (127.0.0.1) with a secret token, and never auto-approve.
- Found a bug? Open an issue and include Menu bar icon → Debug Info.

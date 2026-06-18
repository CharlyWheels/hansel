# TimeTracker

Personal Mac time tracker — a Toggl replacement with iCloud calendar auto-start, passive activity monitoring, and pluggable LLM entry drafting.

See [`~/.claude/plans/i-wanna-build-my-async-lake.md`](file:///Users/carlos.rueda/.claude/plans/i-wanna-build-my-async-lake.md) for design and decisions.

## Build

```bash
make app        # builds .app bundle at build/TimeTracker.app
make run        # builds and launches
make clean      # removes build artifacts
swift test      # unit tests
```

The Makefile compiles the SwiftPM executable in release mode and wraps it in a signed `.app` bundle. Ad-hoc code signing is used so permission dialogs (Calendar, Accessibility, Automation) are attributed to this binary.

## First-run permissions

On first launch the app asks for (in order):

1. **Calendar — Full Access** (for iCloud shared calendars)
2. **Accessibility** (for focused window titles)
3. **Automation** — Safari, Chrome, Arc (for browser tab URLs)

Grant them in `System Settings → Privacy & Security`. The Permissions pane in the app shows live status.

## Logs

`~/Library/Logs/TimeTracker/timetracker-YYYY-MM-DD.log` (JSONL, 14-day rotation). Open from Settings → Debug.

# Hansel

Personal Mac time tracker — a Toggl replacement that works out what you are doing from
your calendar, your todo list, and the apps you have open, and asks before it changes
anything.

## How it decides what you are working on

Activity is sampled every 30 s (frontmost app, window title, browser tab). A pure
`ContextSegmenter` scores that stream for *boundaries* — moments where the app, the
title vocabulary, the URL host or the call state all changed at once — and boosts the
score for an idle gap or a meeting edge. A boundary only counts once the new context has
persisted for a couple of minutes, so glancing at Slack is not a task change.

Only at a settled boundary is the model consulted, and it is asked a narrow question:
*did the task change, and if so exactly when?* Its answer carries a confidence, and its
timestamp is clamped to a window around the machine's own instant — models state times
confidently and get them wrong.

Meetings are detected rather than assumed. `AudioInputMonitor` reads whether anything is
capturing audio (a CoreAudio property read — no permission, no orange dot), combined with
video-call apps, conference URLs and the calendar. An accepted meeting you are visibly
not attending scores below the threshold; a declined invitation, an all-day event or a
block that shows as "free" scores zero.

Nothing is changed without asking. A switch question offers three answers — *Same task*,
*Switch*, *Something else…* — because "the boundary was wrong" and "the boundary was right
but the label was wrong" are different corrections, and only the second should teach the
model a new label. Applied switches stay undoable for 15 minutes.

Every candidate, including the suppressed ones, is written to a `FocusDecision` log,
which is both the debugging surface and the corpus that tunes the thresholds.

## Build

```bash
make app        # builds .app bundle at build/Hansel.app
make run        # builds and launches
make install    # copies to /Applications
make clean      # removes build artifacts
swift test      # unit tests
```

The Makefile compiles the SwiftPM executable in release mode and wraps it in a signed
`.app` bundle. Ad-hoc code signing is used so permission dialogs (Calendar,
Accessibility, Automation) are attributed to this binary.

> Ad-hoc signing gives the binary a new hash on every build, and macOS tracks
> Accessibility grants by hash — so after each rebuild you must toggle Hansel off and on
> in `System Settings → Privacy & Security → Accessibility`. Notification permission is
> keyed by bundle id instead and survives rebuilds.

## First-run permissions

1. **Calendar — Full Access** (for shared and subscribed calendars)
2. **Accessibility** (for focused window titles)
3. **Automation** — Safari, Chrome, Arc (for browser tab URLs)

Grant them in `System Settings → Privacy & Security`. The Permissions pane shows live
status. Microphone and camera detection need no permission at all.

## Settings worth knowing

- **Calendar** — choose which calendars may start tracking, and list your own email
  addresses so Hansel can find your response to an invitation (macOS does not always
  report it on Google accounts).
- **General** — idle and auto-start thresholds, and how long an unanswered switch
  question waits before expiring.
- **AI** — provider, model, and which context fields are sent.

## Data retention

Activity samples are kept 30 days, idle spans 90 days, calendar links 30 days. Time
entries, todos and the catalog are never pruned.

## Logs

`~/Library/Logs/TimeTracker/timetracker-YYYY-MM-DD.log` (JSONL, 14-day rotation). Open
from Settings → Debug.

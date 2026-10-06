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

Joining a calendar meeting is the one exception: when a meeting you are attending is in
progress, has other attendees or a video link, and your microphone turns on, the running entry is closed and the meeting starts
right away, from the moment the call began, with its usual project if a past entry had
the same title. It can be undone from the menu bar for 15 minutes, and turned off in
Settings → General → Meetings. If you started a timer by hand after the meeting began,
Hansel leaves it alone.

Everything else is asked before it changes. A switch question offers three answers — *Same task*,
*Switch*, *Something else…* — because "the boundary was wrong" and "the boundary was right
but the label was wrong" are different corrections, and only the second should teach the
model a new label. Applied switches stay undoable for 15 minutes.

Every candidate, including the suppressed ones, is written to a `FocusDecision` log,
which is both the debugging surface and the corpus that tunes the thresholds.

## Time away from the Mac is not tracked

When you come back after being away (screen locked, Mac asleep, or no keyboard or mouse)
while a timer ran, Hansel removes that time on its own:

- **Short absence** (under 1 hour by default): the entry is split around the gap and the
  same task carries on from your return.
- **Long absence** (1 hour or more, e.g. overnight): the entry is closed at the moment you
  left, and nothing continues by itself.

A notice in the menu bar says what was done and offers **Keep that time** to undo it.
Listening on a call with the screen unlocked counts as present. A locked screen or a
sleeping Mac is always away. A periodic check-in (every 90 min by default) catches a
timer left running by mistake.

Calendar events start a timer only when nothing is running, the event is in progress,
began less than 30 minutes ago, and is one you are attending (not declined, not an
unanswered invite, not a "free" hold). The entry starts at the event's start, but never
earlier than the end of your last entry, nor before you came back to the Mac.

## Build

```bash
make app        # builds .app bundle at build/Hansel.app
make run        # builds and launches
make install    # copies to /Applications
make clean      # removes build artifacts
swift test      # unit tests
```

The Makefile compiles the SwiftPM executable in release mode and wraps it in a signed
`.app` bundle, so permission dialogs (Calendar, Accessibility, Automation) are
attributed to this binary.

### Signing (keep permissions across rebuilds)

By default the bundle is signed ad-hoc. That gives every build a new code hash, and
macOS keys Accessibility, Automation and Keychain access on it — so after each rebuild
you must toggle Hansel off and on in `System Settings → Privacy & Security →
Accessibility`.

To avoid that, create a self-signed code-signing certificate once and the Makefile will
use it automatically:

1. Open **Keychain Access → Certificate Assistant → Create a Certificate…**
2. Name: `Hansel Dev`, Identity Type: *Self-Signed Root*, Certificate Type: *Code Signing*.
3. Run `make app`. The output says `signed with: Hansel Dev`.

Any other identity works too: `make app SIGN_IDENTITY="Apple Development: …"`.

### Why no Docker

This is a native macOS menu-bar app. It needs the window server, Accessibility,
EventKit, CoreAudio and AppleScript, none of which exist inside a Linux container, so it
is deliberately not containerised. `swift test` runs the full test suite locally.

## First-run permissions

1. **Calendar — Full Access** (for shared and subscribed calendars)
2. **Accessibility** (for focused window titles)
3. **Automation** — Safari, Chrome, Arc (for browser tab URLs)

Grant them in `System Settings → Privacy & Security`. The Permissions pane shows live
status. Microphone and camera detection need no permission at all.

## Meetings and proposed todos (Meeting Notes)

Hansel reads the archive of [Meeting Notes](https://github.com/foeken/meeting-notes),
the local meeting recorder, and never writes to it. It follows that app's archive folder
(`~/Documents/Meetings Notes` by default) unless you choose another one in
**Settings → Meetings**. The archive is checked every two minutes.

- **Meetings page**: every finished meeting with its summary, decisions, open questions,
  topics and the transcript. Transcript lines are labelled *Me* (microphone) or *Others*
  (system audio). Meeting Notes does not identify speakers, so on a call that separates
  you from the far end, and in a room it does not. Each meeting is linked to the time
  entry that covers most of it.
- **Proposed todos**: each action item in the summary becomes a proposal with title,
  notes (the original sentence, the moment it was said and a link to the notes), project
  and customer filled in. They wait in an inbox at the top of **Todos**, on the meeting's
  page and in the menu bar, and only become todos when you accept them (✓), edit and
  accept, or decline (✕).
- **Where the project comes from**, strongest first: the project you moved earlier tasks
  from the same recurring meeting to; the time entry covering the meeting; your last
  confirmed entry with the same title; the customer owning the attendees' email domain
  (and its project, if it has only one).
- **Someone else's task**: when the summary names an owner who is not you (set your names
  in Settings → Meetings), the proposal is marked as probably for someone else.
- **AI refinement (opt-in)**: one call per meeting to the default provider rewrites
  titles, picks a project when the rules found none, sets a due date only when one was
  said, and judges whether the task is yours. Without an action item list it finds the
  tasks in the transcript. Proposals you edited, and projects from your own data, are
  never overwritten. It has its own allowance (12 calls/hour, 25/day). It sends meeting
  content to that provider, so it is off by default.
- **Learning**: project corrections per recurring meeting, a warning on meetings whose
  proposals you always decline, and (with AI on) recent declines and title rewrites as
  examples for the model. **Forget…** in Settings → Meetings deletes that history.

## Settings worth knowing

- **Calendar** — choose which calendars may start tracking, and list your own email
  addresses so Hansel can find your response to an invitation (macOS does not always
  report it on Google accounts).
- **General** — idle and auto-start thresholds, when to ask about away time, the
  periodic check-in, and how long an unanswered switch question waits before expiring.
- **Meetings** — Meeting Notes archive folder, the names you go by, AI refinement of
  proposed todos, and the learned history.
- **AI** — provider, model, and which context fields are sent. The toggles apply to
  every prompt, including task-switch questions. The default Claude preset is
  `claude-opus-5-5` at low effort; model calls are capped per hour and per day, and the
  cap survives relaunches.

## Data retention

Activity samples are kept 30 days, idle spans 90 days, calendar links 30 days. Time
entries, todos and the catalog are never pruned. Meetings are mirrored from the Meeting
Notes archive (a meeting deleted there disappears here, with its undecided proposals);
transcripts are read from the archive, never copied. Decided proposals older than 180
days no longer count for learning.

## Logs

`~/Library/Logs/TimeTracker/timetracker-YYYY-MM-DD.log` (JSONL, 14-day rotation). Open
from Settings → Debug. Window and entry titles are not written to this file; in
Console.app they are logged as private.

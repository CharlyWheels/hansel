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
which process holds it (Teams and Zoom capture from helper processes, which count as the
app), the camera being on (CoreMediaIO, no permission), video-call apps, conference URLs
and the calendar: the microphone on during a calendar meeting is enough. Not typing during a call does
not count against it; only a locked screen or sleep does. An accepted meeting you are
visibly not attending scores below the threshold; a declined invitation, an all-day event
or a block that shows as "free" scores zero.

Meetings are the one exception to asking first. When you are in a call, the running entry
is closed and one named after the calendar meeting starts — from when the call began, with
its usual project if a past entry had the same title — even if nothing was running.
Back-to-back meetings each get their own entry at their scheduled start, also while you
just listen. Name and times come from your calendar only; any event in progress that you
have not declined counts, and when several overlap the one that started last wins. A call
with nothing on the calendar is left to the usual question. Hanging up closes the meeting's
entry when the call ended; if the call comes back within 15 minutes the same entry
resumes. Both can be undone from the menu bar for 15 minutes, and turned off in
Settings → General → Meetings. If you started a timer by hand after the meeting began,
Hansel leaves it alone, and it never asks whether you switched tasks during a meeting's
call.

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
the local meeting recorder. The one thing it writes back is a meeting name you corrected (see
*Meeting names*), and that can be turned off. It follows that app's archive folder
(`~/Documents/Meetings Notes` by default) unless you choose another one in
**Settings → Meetings**. The archive is checked every two minutes.

- **Meeting names**: correcting the time entry of a meeting (its *Edit entry* button, or
  the Entries list) renames the meeting too, and a meeting whose entry you named or
  confirmed takes that name. Meeting Notes names a recording after the calendar event
  chosen when it started, which can be the wrong one of overlapping invitations; your
  name is kept when the file is read again. The name is also written into that meeting's
  `meeting.json` (the title only), so Meeting Notes lists it with your name; Meeting Notes
  renames the folder and refreshes its notes itself the next time it starts. Speaker
  names stay in Hansel: Meeting Notes resets speaker labels in its files when it starts.
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

### Who spoke (speaker identification)

Meeting Notes records this Mac's microphone and the call audio as separate files but does
not say who is speaking. Hansel splits each track into voices on this Mac
([FluidAudio](https://github.com/FluidInference/FluidAudio): pyannote + WeSpeaker on
CoreML, a few seconds per meeting; about 20 MB of models downloaded once):

- **Who spoke** on a meeting's page lists each voice with its talk time and three short
  samples to listen to (▶ 1 2 3) — phrases of about six seconds where only that voice
  talks, spread over the meeting, with what was said shown while one plays. Name one, pick a
  known person, or say *This is me*; on a call the main voice on your microphone is
  suggested as you. Very short "voices" (notification chimes, echo) are ignored.
- **Recognised next time**: naming a voice saves its voiceprint, and later meetings
  assign it automatically when the match is close, or suggest it when it is near.
- **AI suggestions** (only with *Refine proposals with AI* and transcript sharing on): the
  model reads the labelled transcript ("thanks, Elena") and proposes names to confirm.
- **What names feed**: the transcript, a *said by* chip on each proposed todo, the
  transcript the AI refinement sees (so it can tell whose task it is), the participant
  list, and the customer of the people who spoke when nothing else gave one.
- Voiceprints never leave this Mac and are never sent to the AI provider. Settings →
  Meetings → Voices lists, merges, renames and deletes them, or turns the feature off.

## Use Hansel from AI assistants (MCP)

Claude Desktop, Claude Code, Codex, Cursor or any other MCP client on this Mac can read
and edit Hansel's data: "how many billable hours this week?", "log 2 h yesterday at 10:00
on the Acme website", "add a todo to send the deck", "stop the timer".

1. Settings → **Integrations** → turn on *Allow AI assistants on this Mac*.
2. Connect the assistant. Every client uses the same command; the tab has copy buttons
   with the exact path:

   ```sh
   # Claude Code
   claude mcp add --scope user hansel -- /Applications/Hansel.app/Contents/MacOS/Hansel --mcp-stdio
   ```

   ```json
   // Claude Desktop: Settings → Developer → Edit Config, then restart Claude
   { "mcpServers": { "hansel": {
       "command": "/Applications/Hansel.app/Contents/MacOS/Hansel", "args": ["--mcp-stdio"] } } }
   ```

   ```toml
   # Codex: ~/.codex/config.toml
   [mcp_servers.hansel]
   command = "/Applications/Hansel.app/Contents/MacOS/Hansel"
   args = ["--mcp-stdio"]
   ```

**Tools**
- Read: `get_today`, `get_running_entry`, `list_entries`, `get_entry`, `list_projects`,
  `list_customers`, `list_roles`, `list_todos`, `list_meetings`, `get_meeting`,
  `list_todo_proposals`, `get_report`, `get_task_context`, `search_context`,
  `get_autonomy_policy`, `get_ingest_brief`, `list_context_items`, `get_dossier_work`.
- Create and edit: `start_timer`, `stop_timer`, `create_entry`, `update_entry`,
  `create_todo`, `update_todo`, `create_project`, `update_project`, `create_customer`,
  `update_customer`, `create_role`, `update_role`, `rename_meeting`,
  `accept_todo_proposal`, `decline_todo_proposal`, `add_context_items`, `update_dossier`, `update_task_brief`, `delegate_todo`,
  `next_delegated_task`, `log_progress`, `ask_user`, `request_approval`, `submit_deliverable`.
- Todos carry their customer; `create_todo` / `update_todo` take one for top-level todos.
  `create_customer` / `update_customer` take `aliases` and `excluded_from_context`, and
  refuse a name or alias another customer already goes by.
- Projects, customers, roles and todos can be named instead of given by id; an ambiguous
  name is refused with the candidates. Times are ISO 8601, local time without an offset.
- Entries that would overlap another entry, or end in the future, are refused rather
  than reshaping the timeline. Edits go through the same code as the app's own editors.

**How it works and what it can't do**
- `Hansel --mcp-stdio` is a relay the assistant starts: it passes each message to the
  running app over a Unix socket at `~/Library/Application Support/TimeTracker/mcp.sock`
  that only your user can open. There is no network port.
- Hansel must be open; otherwise the assistant gets an error saying so.
- Nothing can be deleted through it. Off by default.
- What an assistant reads is sent to its own AI provider, like anything else you show it.
- ChatGPT's web and mobile apps only connect to servers on the internet, so they are not
  supported.

## Customers, aliases and todos

Every todo works for a customer from a closed list. The customer is set on top-level
todos; subtasks work for their root's customer. A project with a customer decides it, so
the two never disagree. Open todos without one show a **No customer** chip in Todos. For
work that is no customer's, create an internal customer such as "Internal".

A customer's **aliases** are the other names it goes by, comma-separated: email domains
(`acme.com`), abbreviations (`ITX`), Slack channels (`#acme-rollout`) and contacts
(`jane@acme.com`). Meetings with people from its domains are attributed to it. Names
and abbreviations count as whole words, ignoring accents and case, except acronyms: an
alias typed in capitals ("AM", "ANF", "BOSS") only counts written in capitals, so "I am"
or "my boss" is not a customer. A new
customer, or an alias, that another customer already goes by is refused ("Inditex",
"inditex" and an existing alias "ITX" are the same customer), so the list has no
duplicates.

**Keep out of AI context** on a customer (e.g. "Personal") keeps its todos, meetings and
messages out of everything gathered as context for AI assistants.

## Context from every source

The **Context** page holds one item per meeting, Slack thread, email conversation, Teams
chat, calendar event, Confluence page or GitHub issue about your work: a short summary,
the facts worth keeping, and a link to the original. Each item belongs to a todo, or to a
customer when no todo fits. These items are what the todos' dossiers will be written from.

- **Meetings** become items on their own once finished. They follow the todo their
  accepted tasks went under (or their time entry's todo), else the attendees' domains
  and the title. A meeting is left out only when every task taken from it is personal,
  and tasks filed under a personal todo are left out of its details.
- **Everything else** is collected by Codex, the assistant that has the Slack, Outlook,
  Teams, Atlassian and GitHub connectors. `scripts/context-ingest/run.sh` runs
  `codex exec` with `scripts/context-ingest/prompt.md`:
  1. Codex asks Hansel what to look for (`get_ingest_brief`).
  2. It reads each source since the last completed run.
  3. It sends short summaries with its suggested todo or customer (`add_context_items`).

  Codex only reads those sources and writes nothing but these items. Hansel makes no
  model calls for this.
- **Where an item goes.** Hansel checks the suggestion against its own signals:
  - Its own signals are the people's email domains, the channel, the contacts in the
    customers' aliases, and a single customer named in the title. A customer named only
    in the summary counts as a hint. Customers named like ordinary words ("Internal",
    "Personal") are only found by their aliases.
  - When both agree, or one is sure and the other has no objection, the item is assigned.
  - When they disagree, or neither is sure, the item waits in the **Inbox** on the Context
    page.
  - Anything about a customer kept out of AI context is not stored.
- **Reading it.** The Context page lists the Inbox, then each customer with its open
  todos, then Discarded. A customer or todo shows its dossier and every item behind it;
  **More** on an item shows its kept facts and **Move…** puts it elsewhere.
- **Gathering context for a new todo.** **Gather context**, on a todo in Context or on its
  todo page, asks Codex to search every source for that todo over the last 90 days,
  however old the items are, and to write its dossier. **Gather context for N new todos**
  in the toolbar does the same for every open todo that has nothing yet, and **Collect
  now** runs the regular collection at once. One collection runs at a time; the page
  shows its progress and the report when it ends.
- **Briefs and the autonomy policy.** So that an agent can do a todo without asking at
  every step:
  - **The brief.** Each todo can have a brief with these sections: Goal, Deliverable,
    Done when, Constraints, and a Plan whose steps are marked `(auto)` or `(ask)`.
    - When an agent starts on a todo without a brief, it drafts one, asks you at most
      three questions, and saves it (`update_task_brief`).
    - It then ticks the steps off as it works.
    - The brief and its progress show on the todo's page and in Context, and you can
      edit it there.
  - **The autonomy policy.** Your rules for agents live in Settings → Integrations →
    *What agents may do on their own*, under three headings: do without asking, ask
    first, never.
    - The policy comes with every `get_task_context` and from `get_autonomy_policy`.
    - Hansel's MCP instructions tell agents to follow it.
- **Delegating todos to agents.** **Delegate to agents**, on a todo's page, in Context, or
  by asking Codex (`delegate_todo`), puts the todo in the agents' queue.
  - **Running them.** **Run agents now**, on the **Agents** page, starts Codex
    (`run.sh --work`, read-only sandbox). They never start on their own. Codex takes one
    queued todo after another (`next_delegated_task`, at most three per run), writes
    or completes its brief, and works through the plan.
  - **What it leaves.** Drafts (unsent emails and Slack messages, pages in your
    personal space), progress (`log_progress`), questions (`ask_user`), the exact
    action for anything that needs your OK (`request_approval`), and the finished work
    (`submit_deliverable`).
  - **Your part.** The Agents page lists what needs you and what is ready for review.
    - Answer a question, approve or reject an action, accept a deliverable (which
      completes the todo), or send it back with what to change.
    - The next run carries on from your decisions. An action is handed back as
      approved only after you approved it in Hansel.
  - The Dashboard shows **Agents need you** when something waits. You can also ask
    Codex in a session to "work on my delegated todos", with the same tools.
- **Dashboard and Analytics.**
  - **On the Dashboard:**
    - each open todo shows its customer and the next step from its dossier, or a
      **Gather context** link when it has none;
    - **Context to place** lists what waits in the inbox;
    - **Latest context** shows the newest meetings, threads, emails and pages, when the
      last collection ran, and a **Collect now** link.
  - **In Analytics**, *Customers, todos and context* compares, for the period, the time
    tracked per customer and per open todo with what happened (items by source). It
    flags customers with a lot going on and no time tracked, and shows how much of the
    collected context was placed automatically.
- **The Inbox.** Assign each item to a todo or customer, or discard it. Assigning offers to
  add the item's domains or channel to the customer's aliases. Your latest decisions are
  shown to Codex as examples on its next run.
- **Dossiers.** Each open todo and each customer has a dossier: a Markdown page with
  these sections: Summary, Status, Decisions, People, Open questions, Next steps and
  Sources.
  - After sending the items, the same Codex run rewrites every dossier that has new
    context (`get_dossier_work` / `update_dossier`). It starts from the current dossier
    and gets only what is new since then.
  - A todo's dossier covers its subtasks. A customer's is written from its todos'
    dossiers plus the items about the customer alone.
  - Hansel refuses a dossier that is missing a section or is too long (6,000 characters
    for a todo, 8,000 for a customer), so old detail is condensed rather than piling up.
  - You can read and edit dossiers on the todo's and the customer's pages. The next
    rewrite starts from your text.
  - Customers kept out of AI context have none.
- **Working on a todo.** Ask any assistant connected to Hansel to "work on the Demo Clustag
  todo". It calls `get_task_context` first, which returns:
  - the todo, its notes and subtasks;
  - its dossier, plus the top-level todo's for a subtask;
  - the Summary, Status and People sections of its customer's dossier;
  - the time logged on it: entries linked to it or its subtasks, plus entries on its
    project that no todo claims;
  - context newer than the dossier;
  - the links to its sources.

  The assistant goes to Slack, email and the other sources only for what is missing.
  `search_context` finds earlier items by customer, project, todo, person, text, source
  or date, and returns summaries with links rather than the original text. Both tools
  leave out customers kept out of AI context.
- **Schedule.** `scripts/context-ingest/install.sh` runs the collection every 3 hours
  through launchd, and a run missed while the Mac slept happens on wake.
  - The scripts ship inside Hansel.app (`Contents/Resources/context-ingest/`), and the job
    runs that copy because launchd may not read `~/Documents`. So `make install` updates
    the scheduled collection too.
  - `INTERVAL_HOURS=6 scripts/context-ingest/install.sh` changes the interval.
  - `scripts/context-ingest/install.sh uninstall` removes it.
  - Logs are written to `~/Library/Logs/TimeTracker/context-ingest-*.log`.
  - Hansel must be running, with *Allow AI assistants on this Mac* on.

## Settings worth knowing

- **Calendar** — choose which calendars may start tracking, and list your own email
  addresses so Hansel can find your response to an invitation (macOS does not always
  report it on Google accounts).
- **General** — idle and auto-start thresholds, when to ask about away time, the
  periodic check-in, and how long an unanswered switch question waits before expiring.
- **Meetings** — Meeting Notes archive folder, the names you go by, AI refinement of
  proposed todos, and the learned history.
- **Integrations** — let AI assistants on this Mac use Hansel through MCP (above).
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

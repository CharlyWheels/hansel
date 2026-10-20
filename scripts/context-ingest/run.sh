#!/bin/zsh
# Collects work context from Slack, email, Teams, the calendar, Confluence and GitHub
# with Codex (the agent that has those connectors) and sends it to Hansel over MCP.
#
#   run.sh                    everything new since the last run (launchd, every few hours)
#   run.sh --todos ID[,ID…]   everything about these todos, however old (Hansel's
#                             "Gather context" button); moves no collection cursor
#   run.sh --work             work on the todos delegated to agents, only when the user
#                             presses "Run agents now" in Hansel; read-only sandbox, so
#                             the agent leaves drafts and requests, never files
#
# Exit codes: 0 done (or Hansel not running), 3 a sending tool was called (see
# send-alert.txt), 75 another run is in progress, else failed.
set -u

SCRIPT_DIR=${0:A:h}
LOG_DIR="$HOME/Library/Logs/TimeTracker"
LOG="$LOG_DIR/context-ingest-$(date +%F).log"
CODEX="${CODEX:-/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex}"
WORKDIR="$HOME/Library/Application Support/TimeTracker/context-ingest"
# In WORKDIR rather than $TMPDIR, which launchd and the app do not share.
LOCK="$WORKDIR/run.lock"

TODOS=""
WORK=""
if [[ "${1:-}" == "--work" ]]; then
  WORK=1
elif [[ "${1:-}" == "--todos" ]]; then
  TODOS="${2:-}"
  if [[ ! "$TODOS" =~ '^[0-9A-Fa-f,-]+$' ]]; then print -u2 "usage: run.sh [--todos ID[,ID…]]"; exit 64; fi
fi

mkdir -p "$LOG_DIR" "$WORKDIR"
log() { print -r -- "$(date '+%F %T') $*" >> "$LOG"; }

# Hansel answers MCP only while it runs; the next run catches up from the same point.
# Started by Hansel itself (HANSEL_RUNNER), it is running; pgrep cannot always see it
# from a process the app launched.
if [[ -z "${HANSEL_RUNNER:-}" ]] && ! pgrep -xq Hansel; then
  log "skip: Hansel is not running"
  exit 0
fi
if [[ ! -x "$CODEX" ]]; then
  log "error: Codex CLI not found at $CODEX"
  exit 1
fi
# One run at a time; a lock older than 2 hours belongs to a run that died.
if ! mkdir "$LOCK" 2>/dev/null; then
  if [[ -n $(find "$LOCK" -maxdepth 0 -mmin +120 2>/dev/null) ]]; then
    rm -rf "$LOCK" && mkdir "$LOCK"
  else
    log "skip: another run is in progress"
    exit 75
  fi
fi
trap 'rm -rf "$LOCK"' EXIT

if [[ -n "$WORK" ]]; then
  log "start work"
  PROMPT=$(cat "$SCRIPT_DIR/prompt-work.md")
  REPORT="$WORKDIR/last-work-report.txt"
elif [[ -n "$TODOS" ]]; then
  log "start todos=$TODOS"
  PROMPT=$(sed "s/{{TODOS}}/$TODOS/g" "$SCRIPT_DIR/prompt-todos.md")
  REPORT="$WORKDIR/last-todos-report.txt"
else
  log "start"
  PROMPT=$(cat "$SCRIPT_DIR/prompt.md")
  REPORT="$WORKDIR/last-report.txt"
fi
rm -f "$REPORT"

# Read-only sandbox: Codex needs no shell or file access, only its connectors and the
# Hansel MCP server. Approvals cannot be answered unattended, so none are asked.
RUN_OUT="$WORKDIR/last-run-output.txt"
print -r -- "$PROMPT" | "$CODEX" exec \
  --skip-git-repo-check \
  --ephemeral \
  --cd "$WORKDIR" \
  --sandbox read-only \
  -c approval_policy='"never"' \
  --output-last-message "$REPORT" \
  - > "$RUN_OUT" 2>&1
exit_code=$?
cat "$RUN_OUT" >> "$LOG"
log "end status=$exit_code"
[[ -f "$REPORT" ]] && { print -r -- "--- report ---"; cat "$REPORT"; print; } >> "$LOG"

# Agents never send. Codex cannot be stopped from calling a connector's sending tools,
# so every run is checked afterwards and any such call is reported loudly.
SENT=$(grep -E '^mcp: codex_apps/[^ ]*(send_email|send_email_on_behalf|reply_to_email|forward_email|send_message|post_message|send_draft)[^ ]* started' "$RUN_OUT" | sort -u)
if [[ -n "$SENT" ]]; then
  log "ALERT: a sending tool was called: $SENT"
  { print -r -- "ALERT: this run called a sending tool. Check your Sent folder and Slack."; print -r -- "$SENT"; } > "$WORKDIR/send-alert.txt"
  exit 3
fi
exit $exit_code

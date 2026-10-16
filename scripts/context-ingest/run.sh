#!/bin/zsh
# Collects work context from Slack, email, Teams, the calendar, Confluence and GitHub
# with Codex (the agent that has those connectors) and sends it to Hansel over MCP.
# Run by launchd (see install.sh) every few hours; safe to run by hand.
set -u

SCRIPT_DIR=${0:A:h}
LOG_DIR="$HOME/Library/Logs/TimeTracker"
LOG="$LOG_DIR/context-ingest-$(date +%F).log"
LOCK="${TMPDIR:-/tmp}/hansel-context-ingest.lock"
CODEX="${CODEX:-/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex}"
WORKDIR="$HOME/Library/Application Support/TimeTracker/context-ingest"

mkdir -p "$LOG_DIR" "$WORKDIR"
log() { print -r -- "$(date '+%F %T') $*" >> "$LOG"; }

# Hansel answers MCP only while it runs; the next run catches up from the same point.
if ! pgrep -xq Hansel; then
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
    exit 0
  fi
fi
trap 'rm -rf "$LOCK"' EXIT

log "start"
# Read-only sandbox: Codex needs no shell or file access, only its connectors and the
# Hansel MCP server. Approvals cannot be answered unattended, so none are asked.
"$CODEX" exec \
  --skip-git-repo-check \
  --ephemeral \
  --cd "$WORKDIR" \
  --sandbox read-only \
  -c approval_policy='"never"' \
  --output-last-message "$WORKDIR/last-report.txt" \
  - < "$SCRIPT_DIR/prompt.md" >> "$LOG" 2>&1
exit_code=$?
log "end status=$exit_code"
[[ -f "$WORKDIR/last-report.txt" ]] && { print -r -- "--- report ---"; cat "$WORKDIR/last-report.txt"; print; } >> "$LOG"
exit $exit_code

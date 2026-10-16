#!/bin/zsh
# Schedules the context collection with launchd: every INTERVAL_HOURS (default 3) while
# you are logged in. A run missed while the Mac slept happens on wake.
# It runs the copy of run.sh inside the installed Hansel.app (launchd may not read
# ~/Documents), so `make install` updates the schedule's scripts too.
#   scripts/context-ingest/install.sh            install or update
#   scripts/context-ingest/install.sh uninstall  remove
set -eu

LABEL="com.hansel.context-ingest"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SCRIPT_DIR=${0:A:h}
RUN="/Applications/Hansel.app/Contents/Resources/context-ingest/run.sh"
INTERVAL_HOURS=${INTERVAL_HOURS:-3}
DOMAIN="gui/$(id -u)"

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true

if [[ "${1:-}" == "uninstall" ]]; then
  rm -f "$PLIST"
  echo "Removed $LABEL"
  exit 0
fi

if [[ ! -x "$RUN" ]]; then
  echo "Hansel.app is not installed with the collection scripts; run 'make install' first." >&2
  exit 1
fi
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/TimeTracker"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string>
    <string>$RUN</string>
  </array>
  <key>StartInterval</key><integer>$(( INTERVAL_HOURS * 3600 ))</integer>
  <key>RunAtLoad</key><false/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/TimeTracker/context-ingest-launchd.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/TimeTracker/context-ingest-launchd.log</string>
</dict>
</plist>
EOF
launchctl bootstrap "$DOMAIN" "$PLIST"
echo "Installed $LABEL: every $INTERVAL_HOURS h. Run now: launchctl kickstart $DOMAIN/$LABEL"

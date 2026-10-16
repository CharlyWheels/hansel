#!/bin/zsh
# Schedules the context collection with launchd: every INTERVAL_HOURS (default 3) while
# you are logged in. A run missed while the Mac slept happens on wake.
# launchd may not read ~/Documents (privacy protection), so the scripts are copied to
# Hansel's support folder and run from there: run this again after changing them.
#   scripts/context-ingest/install.sh            install or update
#   scripts/context-ingest/install.sh uninstall  remove
set -eu

LABEL="com.hansel.context-ingest"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SCRIPT_DIR=${0:A:h}
INSTALL_DIR="$HOME/Library/Application Support/TimeTracker/context-ingest"
INTERVAL_HOURS=${INTERVAL_HOURS:-3}
DOMAIN="gui/$(id -u)"

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true

if [[ "${1:-}" == "uninstall" ]]; then
  rm -f "$PLIST"
  echo "Removed $LABEL"
  exit 0
fi

mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/TimeTracker" "$INSTALL_DIR"
cp "$SCRIPT_DIR/run.sh" "$SCRIPT_DIR/prompt.md" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/run.sh"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string>
    <string>$INSTALL_DIR/run.sh</string>
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

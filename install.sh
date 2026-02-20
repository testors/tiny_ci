#!/usr/bin/env bash
# serve_app: Initial setup
# Creates directory structure, initializes projects.json, registers LaunchAgent

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "[serve_app] Installing..."

# --- Create directories ---
mkdir -p "$SCRIPT_DIR/projects"
mkdir -p "$SCRIPT_DIR/serve"
mkdir -p "$SCRIPT_DIR/logs"

# --- Make scripts executable ---
chmod +x "$SCRIPT_DIR/scripts/build.sh"
chmod +x "$SCRIPT_DIR/scripts/register.sh"
chmod +x "$SCRIPT_DIR/serve.sh"

# --- Initialize projects.json if not present ---
PROJECTS_JSON="$SCRIPT_DIR/serve/projects.json"
if [ ! -f "$PROJECTS_JSON" ]; then
    echo "[]" > "$PROJECTS_JSON"
    echo "[serve_app] Initialized serve/projects.json"
fi

# --- Install LaunchAgent (auto-start HTTP server on login) ---
PLIST_NAME="com.serve_app.plist"
PLIST_FILE="$HOME/Library/LaunchAgents/$PLIST_NAME"
mkdir -p "$HOME/Library/LaunchAgents"

cat > "$PLIST_FILE" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.serve_app</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>-m</string>
        <string>http.server</string>
        <string>8888</string>
        <string>--bind</string>
        <string>0.0.0.0</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${SCRIPT_DIR}/serve</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${SCRIPT_DIR}/logs/serve.log</string>
    <key>StandardErrorPath</key>
    <string>${SCRIPT_DIR}/logs/serve.log</string>
</dict>
</plist>
PLIST

# Remove old logger LaunchAgent if present (unload + delete plist)
OLD_PLIST="$HOME/Library/LaunchAgents/com.logger.local-ci.plist"
if [ -f "$OLD_PLIST" ]; then
    launchctl bootout "gui/$(id -u)" "$OLD_PLIST" 2>/dev/null || true
    rm -f "$OLD_PLIST"
    echo "[serve_app] Removed old logger LaunchAgent (com.logger.local-ci)"
fi

# Load (or reload) the new agent
launchctl bootout "gui/$(id -u)" "$PLIST_FILE" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_FILE"

echo ""
echo "[serve_app] Installation complete!"
echo ""
echo "  HTTP server: running on port 8888 (auto-starts on login)"
echo "  Manage:"
echo "    launchctl kickstart -k gui/$(id -u)/com.serve_app   # restart"
echo "    launchctl bootout gui/$(id -u)/com.serve_app        # stop"
echo ""
echo "  Register a project:"
echo "    cd /path/to/your/project"
echo "    ~/Repos/serve_app/scripts/register.sh"
echo ""

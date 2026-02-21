#!/usr/bin/env bash
# tiny_ci: Initial setup
# Creates directory structure, initializes projects.json, registers LaunchAgent
# Usage: install.sh [--port PORT]   (default: 8888)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PORT=8888

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port) PORT="$2"; shift 2 ;;
        *) echo "Usage: install.sh [--port PORT]" >&2; exit 1 ;;
    esac
done

echo "[tiny_ci] Installing..."

# --- Create directories ---
mkdir -p "$SCRIPT_DIR/projects"
mkdir -p "$SCRIPT_DIR/serve"
mkdir -p "$SCRIPT_DIR/logs"

# --- Make scripts executable ---
chmod +x "$SCRIPT_DIR/scripts/build.sh"
chmod +x "$SCRIPT_DIR/scripts/register.sh"
chmod +x "$SCRIPT_DIR/serve.sh"
chmod +x "$SCRIPT_DIR/server.py"

# --- Initialize projects.json if not present ---
PROJECTS_JSON="$SCRIPT_DIR/serve/projects.json"
if [ ! -f "$PROJECTS_JSON" ]; then
    echo "[]" > "$PROJECTS_JSON"
    echo "[tiny_ci] Initialized serve/projects.json"
fi

# --- Install LaunchAgent (auto-start HTTP server on login) ---
PLIST_NAME="com.tiny_ci.plist"
PLIST_FILE="$HOME/Library/LaunchAgents/$PLIST_NAME"
mkdir -p "$HOME/Library/LaunchAgents"

cat > "$PLIST_FILE" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.tiny_ci</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>${SCRIPT_DIR}/server.py</string>
        <string>${PORT}</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${SCRIPT_DIR}</string>
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

# Remove old LaunchAgents if present (migration)
for OLD_LABEL in com.logger.local-ci com.serve_app; do
    OLD_PLIST="$HOME/Library/LaunchAgents/${OLD_LABEL}.plist"
    if [ -f "$OLD_PLIST" ]; then
        launchctl bootout "gui/$(id -u)" "$OLD_PLIST" 2>/dev/null || true
        rm -f "$OLD_PLIST"
        echo "[tiny_ci] Removed old LaunchAgent (${OLD_LABEL})"
    fi
done

# Load (or reload) the new agent
launchctl bootout "gui/$(id -u)" "$PLIST_FILE" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_FILE"

echo ""
echo "[tiny_ci] Installation complete!"
echo ""
echo "  HTTP server: running on port $PORT (auto-starts on login)"
echo "  Manage:"
echo "    launchctl kickstart -k gui/$(id -u)/com.tiny_ci   # restart"
echo "    launchctl bootout gui/$(id -u)/com.tiny_ci        # stop"
echo ""
echo "  Register a project:"
echo "    cd /path/to/your/project"
echo "    $SCRIPT_DIR/scripts/register.sh"
echo ""

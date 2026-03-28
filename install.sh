#!/usr/bin/env bash
# tiny_ci: Initial setup
# Creates directory structure, initializes projects.json, registers system service
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
chmod +x "$SCRIPT_DIR/scripts/trigger.sh"
chmod +x "$SCRIPT_DIR/scripts/register.sh"
chmod +x "$SCRIPT_DIR/scripts/install_git_hooks.py"
chmod +x "$SCRIPT_DIR/serve.sh"
chmod +x "$SCRIPT_DIR/server.py"

# --- Initialize projects.json if not present ---
PROJECTS_JSON="$SCRIPT_DIR/serve/projects.json"
if [ ! -f "$PROJECTS_JSON" ]; then
    echo "[]" > "$PROJECTS_JSON"
    echo "[tiny_ci] Initialized serve/projects.json"
fi

# --- Install system service ---
if [[ "$OSTYPE" == "darwin"* ]]; then
    # ── macOS: LaunchAgent ──────────────────────────────────────────────────
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

    launchctl bootout "gui/$(id -u)" "$PLIST_FILE" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST_FILE"

    echo ""
    echo "[tiny_ci] Installation complete!"
    echo ""
    echo "  HTTP server: running on port $PORT (auto-starts on login)"
    echo "  Manage:"
    echo "    launchctl kickstart -k gui/$(id -u)/com.tiny_ci   # restart"
    echo "    launchctl bootout gui/$(id -u)/com.tiny_ci        # stop"

else
    # ── Linux: systemd user service ─────────────────────────────────────────
    SYSTEMD_DIR="$HOME/.config/systemd/user"
    UNIT_FILE="$SYSTEMD_DIR/tiny_ci.service"
    mkdir -p "$SYSTEMD_DIR"

    cat > "$UNIT_FILE" <<UNIT
[Unit]
Description=tiny_ci Build Server
After=network.target

[Service]
ExecStart=/usr/bin/python3 ${SCRIPT_DIR}/server.py ${PORT}
WorkingDirectory=${SCRIPT_DIR}
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
UNIT

    systemctl --user daemon-reload
    systemctl --user enable tiny_ci
    systemctl --user restart tiny_ci

    # Allow service to run without an active login session
    loginctl enable-linger "$USER" 2>/dev/null || true

    echo ""
    echo "[tiny_ci] Installation complete!"
    echo ""
    echo "  HTTP server: running on port $PORT (auto-starts on login)"
    echo "  Manage:"
    echo "    systemctl --user restart tiny_ci   # restart"
    echo "    systemctl --user stop tiny_ci      # stop"
fi

# --- Sync git hooks for already registered projects ---
for PROJECT_FILE in "$SCRIPT_DIR"/projects/*.json; do
    [ -f "$PROJECT_FILE" ] || continue

    PROJECT_ID="$(python3 -c "import json; d=json.load(open('$PROJECT_FILE')); print(d['id'])")"
    PROJECT_NAME="$(python3 -c "import json; d=json.load(open('$PROJECT_FILE')); print(d['name'])")"
    PROJECT_REPO="$(python3 -c "import json; d=json.load(open('$PROJECT_FILE')); print(d.get('repoPath', ''))")"

    if [ -z "$PROJECT_REPO" ] || [ ! -d "$PROJECT_REPO" ]; then
        echo "[tiny_ci] Skipping hook sync for ${PROJECT_ID}: missing repoPath"
        continue
    fi

    if ! git -C "$PROJECT_REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "[tiny_ci] Skipping hook sync for ${PROJECT_ID}: not a git repo"
        continue
    fi

    python3 "$SCRIPT_DIR/scripts/install_git_hooks.py" \
        "$PROJECT_REPO" \
        "$PROJECT_ID" \
        "$PROJECT_NAME"
done

echo ""
echo "  Register a project:"
echo "    cd /path/to/your/project"
echo "    $SCRIPT_DIR/scripts/register.sh"
echo ""

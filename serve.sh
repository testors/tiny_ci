#!/usr/bin/env bash
# serve_app: HTTP server (manual start)
# The LaunchAgent usually handles this automatically.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVE_DIR="$SCRIPT_DIR/serve"
PORT="${1:-8888}"

LOCAL_IP=$(ifconfig | grep 'inet ' | grep -v '127.0.0.1' | head -1 | awk '{print $2}')

echo "======================================="
echo "  serve_app - APK Server"
echo "======================================="
echo ""
echo "  http://${LOCAL_IP}:${PORT}"
echo "  http://localhost:${PORT}"
echo ""
echo "  Press Ctrl+C to stop."
echo "======================================="
echo ""

cd "$SERVE_DIR"
python3 -m http.server "$PORT" --bind 0.0.0.0

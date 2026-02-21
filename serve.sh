#!/usr/bin/env bash
# tiny_ci: HTTP server (manual start)
# The LaunchAgent usually handles this automatically.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVE_DIR="$SCRIPT_DIR/serve"
PORT="${1:-8888}"

LOCAL_IP=$(ifconfig | grep 'inet ' | grep -v '127.0.0.1' | head -1 | awk '{print $2}')

echo "======================================="
echo "  tiny_ci - Build Server"
echo "======================================="
echo ""
echo "  http://${LOCAL_IP}:${PORT}"
echo "  http://localhost:${PORT}"
echo ""
echo "  Press Ctrl+C to stop."
echo "======================================="
echo ""

python3 "$SCRIPT_DIR/server.py" "$PORT"

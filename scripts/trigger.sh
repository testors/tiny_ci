#!/usr/bin/env bash
# tiny_ci: detached build trigger for git hooks

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVE_APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ID="${1:?Usage: trigger.sh <project-id>}"
TRIGGER_LOG="$SERVE_APP_DIR/logs/${PROJECT_ID}/trigger.log"

mkdir -p "$(dirname "$TRIGGER_LOG")"

python3 - "$SCRIPT_DIR/build.sh" "$PROJECT_ID" >>"$TRIGGER_LOG" 2>&1 <<'PY'
import subprocess
import sys

build_script, project_id = sys.argv[1], sys.argv[2]
subprocess.Popen(
    [build_script, project_id],
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
    start_new_session=True,
)
PY

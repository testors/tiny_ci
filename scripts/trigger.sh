#!/usr/bin/env bash
# tiny_ci: detached build trigger for git hooks

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVE_APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ID="${1:?Usage: trigger.sh <project-id>}"
REPO_PATH="${2:-}"
TRIGGER_LOG="$SERVE_APP_DIR/logs/${PROJECT_ID}/trigger.log"
PROJECT_FILE="$SERVE_APP_DIR/projects/${PROJECT_ID}.json"

mkdir -p "$(dirname "$TRIGGER_LOG")"

PINNED_BRANCH=""
if [ -f "$PROJECT_FILE" ]; then
    PINNED_BRANCH="$(
        python3 - "$SERVE_APP_DIR" "$PROJECT_FILE" <<'PYEOF'
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[1])

from project_paths import load_project

project = load_project(Path(sys.argv[2]), Path(sys.argv[1]))
print(project.get("branch", ""))
PYEOF
    )"
fi

if [ -n "$PINNED_BRANCH" ] && [ -n "$REPO_PATH" ] && git -C "$REPO_PATH" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    CURRENT_BRANCH="$(git -C "$REPO_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
    if [ "$CURRENT_BRANCH" != "$PINNED_BRANCH" ]; then
        echo "[tiny_ci] Skipping ${PROJECT_ID}: current branch ${CURRENT_BRANCH:-unknown} != pinned ${PINNED_BRANCH}" >>"$TRIGGER_LOG"
        exit 0
    fi
fi

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

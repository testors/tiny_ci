#!/usr/bin/env bash
# serve_app: Register a project
# Run from the project root directory (where .serve_app.json lives)
# Usage: ~/Repos/serve_app/scripts/register.sh

set -euo pipefail

SERVE_APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_ROOT="$(pwd)"
CONFIG_FILE="$PROJECT_ROOT/.serve_app.json"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "[serve_app] ERROR: .serve_app.json not found in $(pwd)" >&2
    echo "  Create it first, then re-run this script." >&2
    exit 1
fi

# --- Read config ---
PROJECT_ID="$(python3 -c "import json; d=json.load(open('$CONFIG_FILE')); print(d['id'])")"
PROJECT_NAME="$(python3 -c "import json; d=json.load(open('$CONFIG_FILE')); print(d['name'])")"
APK_NAME="$(python3 -c "import json; d=json.load(open('$CONFIG_FILE')); print(d['apkName'])")"

echo "[serve_app] Registering project: $PROJECT_NAME ($PROJECT_ID)"

# --- Copy config to serve_app/projects/ ---
# Merge repoPath into the config copy so build.sh can find the git repo
python3 - <<PYEOF
import json
with open('$CONFIG_FILE') as f:
    config = json.load(f)
config['repoPath'] = '$PROJECT_ROOT'
# Resolve relative buildWorkingDir to absolute
if 'buildWorkingDir' in config and not config['buildWorkingDir'].startswith('/'):
    import os
    config['buildWorkingDir'] = os.path.join('$PROJECT_ROOT', config['buildWorkingDir'])
# Resolve relative artifactPath to absolute
if 'artifactPath' in config and not config['artifactPath'].startswith('/'):
    import os
    config['artifactPath'] = os.path.join('$PROJECT_ROOT', config['artifactPath'])
with open('$SERVE_APP_DIR/projects/${PROJECT_ID}.json', 'w') as f:
    json.dump(config, f, ensure_ascii=False, indent=2)
print('[serve_app] Config saved to projects/${PROJECT_ID}.json')
PYEOF

# --- Create serve/<id>/ directory ---
mkdir -p "$SERVE_APP_DIR/serve/${PROJECT_ID}"
mkdir -p "$SERVE_APP_DIR/logs/${PROJECT_ID}"

# --- Initialize build-status.json if not present ---
STATUS_FILE="$SERVE_APP_DIR/serve/${PROJECT_ID}/build-status.json"
if [ ! -f "$STATUS_FILE" ]; then
    cat > "$STATUS_FILE" <<JSON
{
  "status": "unknown",
  "commit": "",
  "commitFull": "",
  "branch": "",
  "message": "No build yet. Make a commit to trigger a build.",
  "timestamp": "",
  "apkSize": 0
}
JSON
fi

# --- Initialize build-history.json if not present ---
HISTORY_FILE="$SERVE_APP_DIR/serve/${PROJECT_ID}/build-history.json"
if [ ! -f "$HISTORY_FILE" ]; then
    echo "[]" > "$HISTORY_FILE"
fi

# --- Update serve/projects.json ---
PROJECTS_JSON="$SERVE_APP_DIR/serve/projects.json"
python3 - <<PYEOF
import json, os

projects_file = '$PROJECTS_JSON'
try:
    with open(projects_file) as f:
        projects = json.load(f)
except:
    projects = []

# Check if already registered
found = False
for p in projects:
    if p.get('id') == '$PROJECT_ID':
        p['name'] = '$PROJECT_NAME'
        p['apkFile'] = '$APK_NAME'
        found = True
        print('[serve_app] Updated existing entry in projects.json')
        break

if not found:
    projects.append({
        'id': '$PROJECT_ID',
        'name': '$PROJECT_NAME',
        'apkFile': '$APK_NAME',
        'status': 'unknown',
        'lastBuildTime': ''
    })
    print('[serve_app] Added new entry to projects.json')

with open(projects_file, 'w') as f:
    json.dump(projects, f, ensure_ascii=False, indent=2)
PYEOF

# --- Install git post-commit hook ---
GIT_DIR="$(git -C "$PROJECT_ROOT" rev-parse --git-dir 2>/dev/null || true)"
if [ -z "$GIT_DIR" ]; then
    echo "[serve_app] WARNING: $PROJECT_ROOT is not a git repository. Skipping hook installation."
else
    # Resolve git dir to absolute path
    if [[ "$GIT_DIR" != /* ]]; then
        GIT_DIR="$PROJECT_ROOT/$GIT_DIR"
    fi
    HOOK_FILE="$GIT_DIR/hooks/post-commit"
    HOOK_MARKER="serve_app/scripts/build.sh ${PROJECT_ID}"

    if [ -f "$HOOK_FILE" ] && grep -qF "$HOOK_MARKER" "$HOOK_FILE"; then
        echo "[serve_app] Git hook already installed for $PROJECT_ID"
    else
        if [ -f "$HOOK_FILE" ]; then
            echo "[serve_app] Appending to existing post-commit hook..."
            echo "" >> "$HOOK_FILE"
        else
            printf '#!/usr/bin/env bash\n' > "$HOOK_FILE"
        fi
        cat >> "$HOOK_FILE" <<HOOK
# serve_app: auto-build ${PROJECT_NAME} on commit
nohup "${SERVE_APP_DIR}/scripts/build.sh" ${PROJECT_ID} > /dev/null 2>&1 &
HOOK
        chmod +x "$HOOK_FILE"
        echo "[serve_app] Git hook installed: $HOOK_FILE"
    fi
fi

echo ""
echo "[serve_app] Registration complete!"
echo ""
echo "  Project: $PROJECT_NAME ($PROJECT_ID)"
echo "  Config:  $SERVE_APP_DIR/projects/${PROJECT_ID}.json"
echo "  Serve:   $SERVE_APP_DIR/serve/${PROJECT_ID}/"
echo ""
echo "  Next steps:"
echo "    1. Run: ~/Repos/serve_app/install.sh   (if not done already)"
echo "    2. Make a commit in $PROJECT_ROOT → build triggers automatically"
echo "    3. Open http://localhost:8888 to monitor builds"
echo ""

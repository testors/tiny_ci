#!/usr/bin/env bash
# tiny_ci: Register a project
# Run from the project root directory (where .tiny_ci.json lives)
# Usage: ~/Repos/tiny_ci/scripts/register.sh

set -euo pipefail

SERVE_APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_ROOT="$(pwd)"
CONFIG_FILE="$PROJECT_ROOT/.tiny_ci.json"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "[tiny_ci] ERROR: .tiny_ci.json not found in $(pwd)" >&2
    echo "  Create it first, then re-run this script." >&2
    exit 1
fi

# --- Read config ---
PROJECT_ID="$(python3 -c "import json; d=json.load(open('$CONFIG_FILE')); print(d['id'])")"
PROJECT_NAME="$(python3 -c "import json; d=json.load(open('$CONFIG_FILE')); print(d['name'])")"
ARTIFACT_NAME="$(python3 -c "import json; d=json.load(open('$CONFIG_FILE')); print(d.get('artifactName') or d['apkName'])")"

echo "[tiny_ci] Registering project: $PROJECT_NAME ($PROJECT_ID)"

# --- Copy config to tiny_ci/projects/ ---
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
# Resolve relative paths in watchArtifacts
for a in config.get('watchArtifacts', []):
    if 'path' in a and not a['path'].startswith('/'):
        import os
        a['path'] = os.path.join('$PROJECT_ROOT', a['path'])
with open('$SERVE_APP_DIR/projects/${PROJECT_ID}.json', 'w') as f:
    json.dump(config, f, ensure_ascii=False, indent=2)
print('[tiny_ci] Config saved to projects/${PROJECT_ID}.json')
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
  "artifactSize": 0
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
        p['artifactFile'] = '$ARTIFACT_NAME'
        found = True
        print('[tiny_ci] Updated existing entry in projects.json')
        break

if not found:
    projects.append({
        'id': '$PROJECT_ID',
        'name': '$PROJECT_NAME',
        'artifactFile': '$ARTIFACT_NAME',
        'status': 'unknown',
        'lastBuildTime': ''
    })
    print('[tiny_ci] Added new entry to projects.json')

with open(projects_file, 'w') as f:
    json.dump(projects, f, ensure_ascii=False, indent=2)
PYEOF

# --- Install git post-commit hook ---
GIT_DIR="$(git -C "$PROJECT_ROOT" rev-parse --git-dir 2>/dev/null || true)"
if [ -z "$GIT_DIR" ]; then
    echo "[tiny_ci] WARNING: $PROJECT_ROOT is not a git repository. Skipping hook installation."
else
    # Resolve git dir to absolute path
    if [[ "$GIT_DIR" != /* ]]; then
        GIT_DIR="$PROJECT_ROOT/$GIT_DIR"
    fi
    HOOK_FILE="$GIT_DIR/hooks/post-commit"
    HOOK_MARKER="build.sh\" ${PROJECT_ID}"

    if [ -f "$HOOK_FILE" ] && grep -qF "$HOOK_MARKER" "$HOOK_FILE"; then
        echo "[tiny_ci] Git hook already installed for $PROJECT_ID"
    else
        if [ -f "$HOOK_FILE" ]; then
            echo "[tiny_ci] Appending to existing post-commit hook..."
            echo "" >> "$HOOK_FILE"
        else
            printf '#!/usr/bin/env bash\n' > "$HOOK_FILE"
        fi
        cat >> "$HOOK_FILE" <<HOOK
# tiny_ci: auto-build ${PROJECT_NAME} on commit
nohup "${SERVE_APP_DIR}/scripts/build.sh" ${PROJECT_ID} > /dev/null 2>&1 &
HOOK
        chmod +x "$HOOK_FILE"
        echo "[tiny_ci] Git hook installed: $HOOK_FILE"
    fi
fi

echo ""
echo "[tiny_ci] Registration complete!"
echo ""
echo "  Project: $PROJECT_NAME ($PROJECT_ID)"
echo "  Config:  $SERVE_APP_DIR/projects/${PROJECT_ID}.json"
echo "  Serve:   $SERVE_APP_DIR/serve/${PROJECT_ID}/"
echo ""
echo "  Next steps:"
echo "    1. Run: ~/Repos/tiny_ci/install.sh   (if not done already)"
echo "    2. Make a commit in $PROJECT_ROOT → build triggers automatically"
echo "    3. Open http://localhost:8888 to monitor builds"
echo ""

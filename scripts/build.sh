#!/usr/bin/env bash
# tiny_ci: Universal build script
# Usage: build.sh <project-id>
# Reads projects/<id>.json, runs buildCommand, serves artifact

set -euo pipefail

SERVE_APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_ID="${1:?Usage: build.sh <project-id>}"

PROJECT_FILE="$SERVE_APP_DIR/projects/${PROJECT_ID}.json"
if [ ! -f "$PROJECT_FILE" ]; then
    echo "[tiny_ci] ERROR: Project config not found: $PROJECT_FILE" >&2
    exit 1
fi

# --- Read project config ---
PROJECT_NAME="$(python3 -c "import json,sys; d=json.load(open('$PROJECT_FILE')); print(d['name'])")"
BUILD_CMD="$(python3 -c "import json,sys; d=json.load(open('$PROJECT_FILE')); print(d['buildCommand'])")"
BUILD_DIR="$(python3 -c "import json,sys; d=json.load(open('$PROJECT_FILE')); print(d.get('buildWorkingDir', '.'))")"
ARTIFACT_PATH="$(python3 -c "import json,sys; d=json.load(open('$PROJECT_FILE')); print(d['artifactPath'])")"
ARTIFACT_NAME="$(python3 -c "import json,sys; d=json.load(open('$PROJECT_FILE')); print(d.get('artifactName') or d['apkName'])")"
PROJECT_REPO="$(python3 -c "import json,sys; d=json.load(open('$PROJECT_FILE')); print(d.get('repoPath', ''))")"

SERVE_DIR="$SERVE_APP_DIR/serve/${PROJECT_ID}"
LOG_DIR="$SERVE_APP_DIR/logs/${PROJECT_ID}"
STATUS_FILE="$SERVE_DIR/build-status.json"
HISTORY_FILE="$SERVE_DIR/build-history.json"
PROJECTS_JSON="$SERVE_APP_DIR/serve/projects.json"
PID_FILE="/tmp/tiny_ci-${PROJECT_ID}.pid"
BUILD_TIMEOUT=300  # 5 minutes

mkdir -p "$SERVE_DIR" "$LOG_DIR"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$LOG_DIR/build-${TIMESTAMP}.log"

# --- Kill process tree recursively ---
kill_tree() {
    local pid="$1"
    local children
    children=$(pgrep -P "$pid" 2>/dev/null || true)
    for child in $children; do
        kill_tree "$child"
    done
    kill "$pid" 2>/dev/null || true
}

# --- Kill previous build if running ---
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE" 2>/dev/null || true)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        echo "[tiny_ci] Killing previous build of $PROJECT_ID (PID $OLD_PID)"
        kill_tree "$OLD_PID"
        sleep 1
    fi
fi
echo $$ > "$PID_FILE"

# --- Gather git info from repo ---
REPO_ROOT="$PROJECT_REPO"
if [ -z "$REPO_ROOT" ]; then
    # Try to infer from buildWorkingDir by searching for .git
    CANDIDATE="$BUILD_DIR"
    while [ "$CANDIDATE" != "/" ] && [ ! -d "$CANDIDATE/.git" ]; do
        CANDIDATE="$(dirname "$CANDIDATE")"
    done
    if [ -d "$CANDIDATE/.git" ]; then
        REPO_ROOT="$CANDIDATE"
    fi
fi

if [ -n "$REPO_ROOT" ] && [ -d "$REPO_ROOT/.git" ]; then
    COMMIT_HASH="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
    COMMIT_FULL="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo '')"
    BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')"
    COMMIT_MSG="$(git -C "$REPO_ROOT" log -1 --pretty=%s 2>/dev/null || echo '')"
else
    COMMIT_HASH="unknown"
    COMMIT_FULL=""
    BRANCH="unknown"
    COMMIT_MSG=""
fi

# --- Write status helper ---
write_status() {
    local status="$1"
    local extra="${2:-}"
    local now
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    local artifact_size=""
    if [ "$status" = "ready" ] && [ -f "$SERVE_DIR/$ARTIFACT_NAME" ]; then
        artifact_size=$(stat -f%z "$SERVE_DIR/$ARTIFACT_NAME" 2>/dev/null || stat -c%s "$SERVE_DIR/$ARTIFACT_NAME" 2>/dev/null || echo "0")
    fi

    cat > "$STATUS_FILE" <<EOJSON
{
  "status": "${status}",
  "commit": "${COMMIT_HASH}",
  "commitFull": "${COMMIT_FULL}",
  "branch": "${BRANCH}",
  "message": $(printf '%s' "$COMMIT_MSG" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))'),
  "timestamp": "${now}",
  "artifactSize": ${artifact_size:-0}${extra:+,
  "error": $(printf '%s' "$extra" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')}
}
EOJSON
}

# --- Update projects.json for this project ---
update_projects_json() {
    local status="$1"
    local now
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    python3 - <<PYEOF
import json, sys, os

projects_file = '$PROJECTS_JSON'
try:
    with open(projects_file) as f:
        projects = json.load(f)
except:
    projects = []

# Find and update or add entry
found = False
for p in projects:
    if p.get('id') == '$PROJECT_ID':
        p['status'] = '$status'
        p['lastBuildTime'] = '$now'
        found = True
        break

if not found:
    projects.append({
        'id': '$PROJECT_ID',
        'name': '$PROJECT_NAME',
        'artifactFile': '$ARTIFACT_NAME',
        'status': '$status',
        'lastBuildTime': '$now'
    })

with open(projects_file, 'w') as f:
    json.dump(projects, f, ensure_ascii=False, indent=2)
PYEOF
}

# --- Strip quarantine from a dir if the sentinel binary is quarantined ---
# Homebrew updates and first-run Gatekeeper checks can add com.apple.quarantine
# to downloaded binaries, causing a blocking GUI dialog in non-interactive builds.
strip_quarantine_if_needed() {
    local label="$1"
    local sentinel="$2"
    local target_dir="$3"
    if [ ! -f "$sentinel" ]; then return; fi
    if xattr "$sentinel" 2>/dev/null | grep -q com.apple.quarantine; then
        echo "[tiny_ci] Removing quarantine from $label..."
        xattr -r -d com.apple.quarantine "$target_dir" 2>/dev/null || true
    fi
}

# --- Flutter SDK ---
handle_flutter_quarantine() {
    local flutter_sdk=""

    # Follow the flutter symlink to locate the real SDK root
    local flutter_bin
    flutter_bin="$(command -v flutter 2>/dev/null || true)"
    if [ -n "$flutter_bin" ]; then
        local real_bin
        real_bin="$(readlink "$flutter_bin" 2>/dev/null || true)"
        if [ -n "$real_bin" ]; then
            [[ "$real_bin" == /* ]] || real_bin="$(dirname "$flutter_bin")/$real_bin"
            flutter_sdk="$(cd "$(dirname "$real_bin")/../.." 2>/dev/null && pwd || true)"
        else
            flutter_sdk="$(cd "$(dirname "$flutter_bin")/.." 2>/dev/null && pwd || true)"
        fi
    fi
    # Fallback: Homebrew formula default location
    if [ -z "$flutter_sdk" ] || [ ! -d "$flutter_sdk/bin/cache" ]; then
        flutter_sdk="/opt/homebrew/share/flutter"
    fi

    strip_quarantine_if_needed "Flutter SDK" \
        "$flutter_sdk/bin/cache/dart-sdk/bin/dart" \
        "$flutter_sdk"
}

# --- Android SDK build-tools & platform-tools ---
# Flutter downloads these on first build; subsequent Homebrew updates can re-quarantine.
handle_android_quarantine() {
    local android_sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
    if [ ! -d "$android_sdk" ]; then return; fi

    # aapt in build-tools as sentinel; fall back to adb
    local sentinel
    sentinel="$(find "$android_sdk/build-tools" -name "aapt" -type f 2>/dev/null | head -1 || true)"
    [ -n "$sentinel" ] || sentinel="$android_sdk/platform-tools/adb"

    strip_quarantine_if_needed "Android SDK" "$sentinel" "$android_sdk"
}

# --- Gradle wrapper distributions ---
# Gradle downloads its own distribution zip and unpacks it; the binaries get quarantined.
handle_gradle_quarantine() {
    local gradle_dists="$HOME/.gradle/wrapper/dists"
    if [ ! -d "$gradle_dists" ]; then return; fi

    local sentinel
    sentinel="$(find "$gradle_dists" -name "gradle" -type f 2>/dev/null | head -1 || true)"

    strip_quarantine_if_needed "Gradle wrapper" "$sentinel" "$gradle_dists"
}

# --- Flutter-specific: clean incremental cache ---
handle_flutter_cache() {
    local flutter_build_dir="$BUILD_DIR/.dart_tool/flutter_build"
    if [ -d "$flutter_build_dir" ]; then
        rm -rf "$flutter_build_dir"
    fi
}

# --- Pre-build: strip quarantine and clean caches ---
# Android SDK + Gradle quarantine applies to any Gradle or Flutter build
if echo "$BUILD_CMD" | grep -qiE 'gradle|flutter'; then
    handle_android_quarantine
    handle_gradle_quarantine
fi
# Flutter-specific steps
if echo "$BUILD_CMD" | grep -qi flutter; then
    handle_flutter_quarantine
    handle_flutter_cache
fi

write_status "building"
update_projects_json "building"
echo "[tiny_ci] Building $PROJECT_NAME (${BRANCH}@${COMMIT_HASH})..."

# --- Build ---
# Write directly to serve/<id>/build.log so it's live-accessible via HTTP during build.
# Archived to logs/<id>/build-<timestamp>.log after completion.
BUILD_LOG_SERVE="$SERVE_DIR/build.log"
> "$BUILD_LOG_SERVE"  # clear previous log

BUILD_EXIT=0
{
    echo "=== tiny_ci Build ==="
    echo "Project: $PROJECT_NAME ($PROJECT_ID)"
    echo "Time:    $(date)"
    echo "Branch:  $BRANCH"
    echo "Commit:  $COMMIT_HASH"
    echo "Command: $BUILD_CMD"
    echo "WorkDir: $BUILD_DIR"
    echo "========================"
    echo ""

    export PATH="/opt/homebrew/opt/openjdk@17/bin:/opt/homebrew/bin:/usr/bin:/bin:$PATH"
    export JAVA_HOME="/opt/homebrew/opt/openjdk@17"

    cd "$BUILD_DIR"
    eval "$BUILD_CMD" 2>&1 || BUILD_EXIT=$?

    echo ""
    echo "=== Build finished (exit=$BUILD_EXIT) ==="
} >> "$BUILD_LOG_SERVE" 2>&1 &
BUILD_PID=$!

# --- Watchdog: kill build if it exceeds timeout ---
(
    sleep "$BUILD_TIMEOUT"
    if kill -0 "$BUILD_PID" 2>/dev/null; then
        echo "[tiny_ci] Build timed out after ${BUILD_TIMEOUT}s, killing..." >> "$BUILD_LOG_SERVE"
        kill_tree "$BUILD_PID"
    fi
) &
WATCHDOG_PID=$!

wait "$BUILD_PID" 2>/dev/null || BUILD_EXIT=$?
kill "$WATCHDOG_PID" 2>/dev/null || true
wait "$WATCHDOG_PID" 2>/dev/null || true

# Archive full log with timestamp
cp "$BUILD_LOG_SERVE" "$LOG_FILE"

if [ $BUILD_EXIT -eq 0 ] && [ -f "$ARTIFACT_PATH" ]; then
    # Atomic copy: temp file + mv
    cp "$ARTIFACT_PATH" "$SERVE_DIR/${ARTIFACT_NAME}.tmp"
    mv "$SERVE_DIR/${ARTIFACT_NAME}.tmp" "$SERVE_DIR/$ARTIFACT_NAME"
    write_status "ready"
    update_projects_json "ready"
    echo "[tiny_ci] Build SUCCESS - $ARTIFACT_NAME ready"
    BUILD_RESULT="ready"
else
    ERROR_MSG=$(tail -20 "$BUILD_LOG_SERVE" | tr '\n' '\x0a' | cut -c1-500)
    write_status "failed" "$ERROR_MSG"
    update_projects_json "failed"
    echo "[tiny_ci] Build FAILED - check $LOG_FILE"
    BUILD_RESULT="failed"
fi

# --- Append to build history (keep last 20) ---
HISTORY_ENTRY=$(python3 -c "
import json, sys
entry = {
    'status': '$BUILD_RESULT',
    'commit': '$COMMIT_HASH',
    'branch': '$BRANCH',
    'message': sys.stdin.read().strip(),
    'timestamp': '$(date -u +%Y-%m-%dT%H:%M:%SZ)'
}
try:
    with open('$HISTORY_FILE') as f:
        history = json.load(f)
except:
    history = []
history.insert(0, entry)
history = history[:20]
print(json.dumps(history, ensure_ascii=False, indent=2))
" <<< "$COMMIT_MSG")
echo "$HISTORY_ENTRY" > "$HISTORY_FILE"

# --- Cleanup old logs (keep 10 most recent) ---
ls -1t "$LOG_DIR"/build-*.log 2>/dev/null | tail -n +11 | xargs rm -f 2>/dev/null || true

# --- Cleanup PID file ---
rm -f "$PID_FILE"

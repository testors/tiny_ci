#!/usr/bin/env python3
"""serve_app HTTP server
- Serves static files from serve/
- POST /api/build/<project-id>  → triggers build.sh in background
- GET  /api/scan/<project-id>   → check repo for newer APKs, copy & return artifacts.json
"""

import http.server
import subprocess
import json
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path

SERVE_APP_DIR = Path(__file__).parent
SERVE_DIR     = SERVE_APP_DIR / "serve"
BUILD_SCRIPT  = SERVE_APP_DIR / "scripts" / "build.sh"


def scan_artifacts(project_id):
    """Compare repo build outputs against served files.
    Copy anything newer, write artifacts.json, return artifact list.
    Returns None if project not found, [] if no watchArtifacts configured.
    """
    project_file = SERVE_APP_DIR / "projects" / f"{project_id}.json"
    if not project_file.exists():
        return None

    with open(project_file) as f:
        config = json.load(f)

    watch_artifacts = config.get("watchArtifacts", [])
    if not watch_artifacts:
        return []

    serve_dir = SERVE_DIR / project_id
    serve_dir.mkdir(parents=True, exist_ok=True)

    # serve_app build timestamp — used to determine if an artifact is "local"
    # (built by the developer directly, after the last serve_app build)
    build_mtime = 0.0
    status_file = serve_dir / "build-status.json"
    if status_file.exists():
        try:
            with open(status_file) as f:
                ts = json.load(f).get("timestamp", "")
            if ts:
                build_mtime = datetime.fromisoformat(
                    ts.replace("Z", "+00:00")
                ).timestamp()
        except Exception:
            pass

    result = []
    for artifact in watch_artifacts:
        src     = Path(artifact["path"])
        dst     = serve_dir / artifact["file"]
        label   = artifact.get("label", artifact["file"])
        info    = {"label": label, "file": artifact["file"], "available": False, "newer": False}

        src_exists  = src.exists()
        src_mtime   = src.stat().st_mtime if src_exists else 0.0
        dst_exists  = dst.exists()
        dst_mtime   = dst.stat().st_mtime if dst_exists else 0.0

        # Copy if the repo's file is newer than what's currently served
        if src_exists and src_mtime > dst_mtime:
            tmp = serve_dir / (artifact["file"] + ".tmp")
            shutil.copy2(str(src), str(tmp))  # preserves mtime
            tmp.rename(dst)
            dst_exists = True
            dst_mtime  = dst.stat().st_mtime

        if dst_exists:
            stat = dst.stat()
            info["available"] = True
            info["size"]      = stat.st_size
            info["mtime"]     = datetime.fromtimestamp(
                stat.st_mtime, tz=timezone.utc
            ).strftime("%Y-%m-%dT%H:%M:%SZ")
            # "newer" = the artifact in the repo was built after the last serve_app build
            # → developer built it locally and it's more recent
            info["newer"] = src_mtime > build_mtime if src_exists else dst_mtime > build_mtime

        result.append(info)

    # Persist so the UI can also poll artifacts.json directly
    artifacts_file = serve_dir / "artifacts.json"
    with open(artifacts_file, "w") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)

    return result


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(SERVE_DIR), **kwargs)

    def do_GET(self):
        # GET /api/scan/<project-id>
        parts = self.path.split("?")[0].strip("/").split("/")
        if len(parts) == 3 and parts[0] == "api" and parts[1] == "scan":
            project_id = parts[2]
            result = scan_artifacts(project_id)
            if result is None:
                self._json(404, {"error": f"project '{project_id}' not found"})
            else:
                self._json(200, result)
        else:
            super().do_GET()

    def do_POST(self):
        # POST /api/build/<project-id>
        parts = self.path.strip("/").split("/")
        if len(parts) == 3 and parts[0] == "api" and parts[1] == "build":
            project_id = parts[2]
            project_file = SERVE_APP_DIR / "projects" / f"{project_id}.json"

            if not project_file.exists():
                self._json(404, {"error": f"project '{project_id}' not found"})
                return

            subprocess.Popen(
                [str(BUILD_SCRIPT), project_id],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
            self._json(202, {"status": "triggered", "project": project_id})
        else:
            self._json(404, {"error": "not found"})

    def _json(self, code, data):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", len(body))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass  # suppress per-request noise in daemon logs


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8888
    server = http.server.HTTPServer(("0.0.0.0", port), Handler)
    print(f"[serve_app] Server running on port {port}", flush=True)
    server.serve_forever()

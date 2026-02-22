#!/usr/bin/env python3
"""tiny_ci HTTP server
- Serves static files from serve/
- POST /api/build/<project-id>  → triggers build.sh in background
- GET  /api/scan/<project-id>   → check repo for build artifacts, return metadata
- GET  /<project-id>/<file>     → serve artifact (lazy copy from repo on first download)
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


def _load_project(project_id):
    """Load project config. Returns (config, watch_artifacts) or (None, None)."""
    project_file = SERVE_APP_DIR / "projects" / f"{project_id}.json"
    if not project_file.exists():
        return None, None
    with open(project_file) as f:
        config = json.load(f)
    return config, config.get("watchArtifacts", [])


def _build_mtime(project_id):
    """Get the last tiny_ci build timestamp as epoch float."""
    status_file = SERVE_DIR / project_id / "build-status.json"
    if not status_file.exists():
        return 0.0
    try:
        with open(status_file) as f:
            ts = json.load(f).get("timestamp", "")
        if ts:
            return datetime.fromisoformat(
                ts.replace("Z", "+00:00")
            ).timestamp()
    except Exception:
        pass
    return 0.0


def scan_artifacts(project_id):
    """Check repo build outputs — metadata only, no file copying.
    Returns None if project not found, [] if no watchArtifacts configured.
    """
    config, watch_artifacts = _load_project(project_id)
    if config is None:
        return None
    if not watch_artifacts:
        return []

    build_mt = _build_mtime(project_id)

    result = []
    for artifact in watch_artifacts:
        src   = Path(artifact["path"])
        label = artifact.get("label", artifact["file"])
        info  = {"label": label, "file": artifact["file"], "available": False, "newer": False}

        if src.exists():
            stat = src.stat()
            info["available"] = True
            info["size"]      = stat.st_size
            info["mtime"]     = datetime.fromtimestamp(
                stat.st_mtime, tz=timezone.utc
            ).strftime("%Y-%m-%dT%H:%M:%SZ")
            info["newer"] = stat.st_mtime > build_mt

        result.append(info)

    # Persist for direct polling
    serve_dir = SERVE_DIR / project_id
    serve_dir.mkdir(parents=True, exist_ok=True)
    with open(serve_dir / "artifacts.json", "w") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)

    return result


def _lazy_copy_artifact(project_id, filename):
    """Copy artifact from repo source to serve dir on demand.
    Returns the serve path if successful, None otherwise.
    """
    config, watch_artifacts = _load_project(project_id)
    if config is None:
        return None

    for artifact in watch_artifacts:
        if artifact["file"] == filename:
            src = Path(artifact["path"])
            if not src.exists():
                return None
            serve_dir = SERVE_DIR / project_id
            serve_dir.mkdir(parents=True, exist_ok=True)
            dst = serve_dir / filename
            # Copy if source is newer than served copy (or served copy doesn't exist)
            src_mtime = src.stat().st_mtime
            dst_mtime = dst.stat().st_mtime if dst.exists() else 0.0
            if src_mtime > dst_mtime:
                tmp = serve_dir / (filename + ".tmp")
                shutil.copy2(str(src), str(tmp))
                tmp.rename(dst)
            return dst

    return None


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(SERVE_DIR), **kwargs)

    def do_GET(self):
        parts = self.path.split("?")[0].strip("/").split("/")

        # GET /api/scan/<project-id>
        if len(parts) == 3 and parts[0] == "api" and parts[1] == "scan":
            project_id = parts[2]
            result = scan_artifacts(project_id)
            if result is None:
                self._json(404, {"error": f"project '{project_id}' not found"})
            else:
                self._json(200, result)
            return

        # GET /<project-id>/<file> — lazy copy for watchArtifact downloads
        if len(parts) == 2:
            project_id, filename = parts
            serve_path = SERVE_DIR / project_id / filename
            if not serve_path.exists():
                _lazy_copy_artifact(project_id, filename)

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
    print(f"[tiny_ci] Server running on port {port}", flush=True)
    server.serve_forever()

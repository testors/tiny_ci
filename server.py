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
import os
import shutil
import sys
import urllib.parse
import email.utils
from http import HTTPStatus
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
    INDEX_PAGES = ("index.html", "index.htm")

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(SERVE_DIR), **kwargs)
        self._range = None

    @staticmethod
    def _parse_range_header(range_header, size):
        if not range_header:
            return None
        if size <= 0 or not range_header.startswith("bytes="):
            raise ValueError("invalid range")

        spec = range_header[6:].strip()
        if "," in spec:
            raise ValueError("multiple ranges not supported")

        start_s, sep, end_s = spec.partition("-")
        if sep != "-":
            raise ValueError("invalid range")

        start_s = start_s.strip()
        end_s = end_s.strip()

        if not start_s:
            if not end_s:
                raise ValueError("invalid range")
            suffix_len = int(end_s)
            if suffix_len <= 0:
                raise ValueError("invalid range")
            suffix_len = min(suffix_len, size)
            return size - suffix_len, size - 1

        start = int(start_s)
        if start < 0 or start >= size:
            raise ValueError("range out of bounds")

        if not end_s:
            return start, size - 1

        end = int(end_s)
        if end < start:
            raise ValueError("invalid range")

        return start, min(end, size - 1)

    def _prepare_artifact(self):
        parts = self.path.split("?")[0].strip("/").split("/")
        if len(parts) != 2:
            return

        project_id, filename = parts
        if not (SERVE_APP_DIR / "projects" / f"{project_id}.json").exists():
            return

        serve_path = SERVE_DIR / project_id / filename
        if not serve_path.exists():
            _lazy_copy_artifact(project_id, filename)

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
            self._prepare_artifact()

        super().do_GET()

    def do_HEAD(self):
        self._prepare_artifact()
        super().do_HEAD()

    def send_head(self):
        self._range = None
        path = self.translate_path(self.path)
        f = None

        if os.path.isdir(path):
            parts = urllib.parse.urlsplit(self.path)
            if not parts.path.endswith(("/", "%2f", "%2F")):
                self.send_response(HTTPStatus.MOVED_PERMANENTLY)
                new_parts = (parts[0], parts[1], parts[2] + "/", parts[3], parts[4])
                new_url = urllib.parse.urlunsplit(new_parts)
                self.send_header("Location", new_url)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return None
            index_pages = getattr(self, "index_pages", self.INDEX_PAGES)
            for index in index_pages:
                index = os.path.join(path, index)
                if os.path.isfile(index):
                    path = index
                    break
            else:
                return self.list_directory(path)

        ctype = self.guess_type(path)
        if path.endswith("/"):
            self.send_error(HTTPStatus.NOT_FOUND, "File not found")
            return None

        try:
            f = open(path, "rb")
        except OSError:
            self.send_error(HTTPStatus.NOT_FOUND, "File not found")
            return None

        try:
            fs = os.fstat(f.fileno())
            if "If-Modified-Since" in self.headers and "If-None-Match" not in self.headers:
                try:
                    ims = email.utils.parsedate_to_datetime(self.headers["If-Modified-Since"])
                except (TypeError, IndexError, OverflowError, ValueError):
                    pass
                else:
                    if ims.tzinfo is None:
                        ims = ims.replace(tzinfo=timezone.utc)
                    if ims.tzinfo is timezone.utc:
                        last_modif = datetime.fromtimestamp(fs.st_mtime, timezone.utc)
                        last_modif = last_modif.replace(microsecond=0)
                        if last_modif <= ims:
                            self.send_response(HTTPStatus.NOT_MODIFIED)
                            self.end_headers()
                            f.close()
                            return None

            try:
                requested_range = self._parse_range_header(self.headers.get("Range"), fs.st_size)
            except ValueError:
                self.send_response(HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE)
                self.send_header("Content-Range", f"bytes */{fs.st_size}")
                self.send_header("Content-Length", "0")
                self.send_header("Accept-Ranges", "bytes")
                self.end_headers()
                f.close()
                return None

            if requested_range is None:
                self.send_response(HTTPStatus.OK)
                self.send_header("Content-type", ctype)
                self.send_header("Content-Length", str(fs.st_size))
            else:
                start, end = requested_range
                self._range = (start, end)
                self.send_response(HTTPStatus.PARTIAL_CONTENT)
                self.send_header("Content-type", ctype)
                self.send_header("Content-Length", str(end - start + 1))
                self.send_header("Content-Range", f"bytes {start}-{end}/{fs.st_size}")

            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Last-Modified", self.date_time_string(fs.st_mtime))
            self.end_headers()
            return f
        except Exception:
            f.close()
            raise

    def copyfile(self, source, outputfile):
        if self._range is None:
            return super().copyfile(source, outputfile)

        start, end = self._range
        remaining = end - start + 1
        source.seek(start)
        while remaining > 0:
            chunk = source.read(min(64 * 1024, remaining))
            if not chunk:
                break
            outputfile.write(chunk)
            remaining -= len(chunk)

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

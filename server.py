#!/usr/bin/env python3
"""serve_app HTTP server
- Serves static files from serve/
- POST /api/build/<project-id>  → triggers build.sh in background
"""

import http.server
import subprocess
import json
import sys
from pathlib import Path

SERVE_APP_DIR = Path(__file__).parent
SERVE_DIR     = SERVE_APP_DIR / "serve"
BUILD_SCRIPT  = SERVE_APP_DIR / "scripts" / "build.sh"


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(SERVE_DIR), **kwargs)

    def do_POST(self):
        # Only accept: POST /api/build/<project-id>
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

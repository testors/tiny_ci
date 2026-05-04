#!/usr/bin/env python3
"""Upload an APK or Android App Bundle to a Google Play testing track.

Uses only Python stdlib plus the system `openssl` binary for RS256 service
account signing, so tiny_ci does not need vendored Python dependencies.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


ANDROIDPUBLISHER_SCOPE = "https://www.googleapis.com/auth/androidpublisher"
DEFAULT_TOKEN_URI = "https://oauth2.googleapis.com/token"
API_BASE = "https://androidpublisher.googleapis.com/androidpublisher/v3"
UPLOAD_BASE = "https://androidpublisher.googleapis.com/upload/androidpublisher/v3"


class PlayUploadError(RuntimeError):
    pass


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


def json_b64url(payload: dict) -> str:
    return b64url(json.dumps(payload, separators=(",", ":")).encode("utf-8"))


def sign_rs256(signing_input: str, private_key: str) -> bytes:
    key_path = ""
    result: subprocess.CompletedProcess[bytes] | None = None
    try:
        with tempfile.NamedTemporaryFile("w", delete=False) as key_file:
            key_path = key_file.name
            os.chmod(key_path, 0o600)
            key_file.write(private_key)

        result = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", key_path],
            input=signing_input.encode("ascii"),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    finally:
        if key_path:
            try:
                os.unlink(key_path)
            except FileNotFoundError:
                pass

    if result is None:
        raise PlayUploadError("openssl was not invoked")
    if result.returncode != 0:
        stderr = result.stderr.decode("utf-8", errors="replace").strip()
        raise PlayUploadError(f"openssl failed to sign service-account JWT: {stderr}")
    return result.stdout


def load_credentials(path: str | None) -> dict:
    credential_path = (
        path
        or os.environ.get("GOOGLE_PLAY_SERVICE_ACCOUNT_JSON")
        or os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
    )
    if not credential_path:
        raise PlayUploadError(
            "service-account JSON is not configured; set playUpload.serviceAccountJson "
            "or GOOGLE_PLAY_SERVICE_ACCOUNT_JSON"
        )

    with Path(credential_path).expanduser().open() as f:
        credentials = json.load(f)

    missing = [key for key in ("client_email", "private_key") if not credentials.get(key)]
    if missing:
        raise PlayUploadError(f"service-account JSON is missing: {', '.join(missing)}")
    return credentials


def fetch_access_token(credentials: dict) -> str:
    token_uri = credentials.get("token_uri") or DEFAULT_TOKEN_URI
    now = int(time.time())
    header = {"alg": "RS256", "typ": "JWT"}
    claims = {
        "iss": credentials["client_email"],
        "scope": ANDROIDPUBLISHER_SCOPE,
        "aud": token_uri,
        "iat": now,
        "exp": now + 3600,
    }
    signing_input = f"{json_b64url(header)}.{json_b64url(claims)}"
    assertion = f"{signing_input}.{b64url(sign_rs256(signing_input, credentials['private_key']))}"

    body = urllib.parse.urlencode(
        {
            "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
            "assertion": assertion,
        }
    ).encode("utf-8")
    response = http_request(
        "POST",
        token_uri,
        body=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        access_token=None,
    )
    token = response.get("access_token")
    if not token:
        raise PlayUploadError("OAuth token response did not include access_token")
    return token


def http_request(
    method: str,
    url: str,
    *,
    access_token: str | None,
    body: bytes | None = None,
    headers: dict[str, str] | None = None,
) -> dict:
    request_headers = dict(headers or {})
    if access_token:
        request_headers["Authorization"] = f"Bearer {access_token}"

    request = urllib.request.Request(
        url,
        data=body,
        headers=request_headers,
        method=method,
    )
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            raw = response.read()
    except urllib.error.HTTPError as exc:
        raw_error = exc.read().decode("utf-8", errors="replace")
        raise PlayUploadError(f"{method} {url} failed: HTTP {exc.code}: {raw_error}") from exc
    except urllib.error.URLError as exc:
        raise PlayUploadError(f"{method} {url} failed: {exc.reason}") from exc

    if not raw:
        return {}
    try:
        return json.loads(raw.decode("utf-8"))
    except json.JSONDecodeError as exc:
        raise PlayUploadError(f"{method} {url} returned non-JSON response") from exc


def api_json(
    method: str,
    url: str,
    *,
    access_token: str,
    payload: dict | None = None,
) -> dict:
    body = json.dumps(payload or {}, separators=(",", ":")).encode("utf-8")
    return http_request(
        method,
        url,
        access_token=access_token,
        body=body,
        headers={"Content-Type": "application/json; charset=utf-8"},
    )


def quote_path(value: str) -> str:
    return urllib.parse.quote(value, safe="")


def create_edit(package_name: str, access_token: str) -> str:
    url = f"{API_BASE}/applications/{quote_path(package_name)}/edits"
    response = api_json("POST", url, access_token=access_token)
    edit_id = response.get("id")
    if not edit_id:
        raise PlayUploadError("edits.insert response did not include edit id")
    return edit_id


def delete_edit(package_name: str, edit_id: str, access_token: str) -> None:
    url = f"{API_BASE}/applications/{quote_path(package_name)}/edits/{quote_path(edit_id)}"
    try:
        http_request("DELETE", url, access_token=access_token)
    except PlayUploadError:
        pass


def resolve_artifact_type(artifact_path: Path, artifact_type: str) -> str:
    if artifact_type == "auto":
        suffix = artifact_path.suffix.lower()
        if suffix == ".aab":
            return "aab"
        if suffix == ".apk":
            return "apk"
        raise PlayUploadError(
            f"cannot infer artifact type from extension: {artifact_path}"
        )
    return artifact_type


def upload_artifact(
    package_name: str,
    edit_id: str,
    artifact_path: Path,
    artifact_type: str,
    access_token: str,
) -> int:
    artifact_type = resolve_artifact_type(artifact_path, artifact_type)

    if artifact_type == "aab":
        collection = "bundles"
        content_type = "application/octet-stream"
        response_label = "Bundle"
    elif artifact_type == "apk":
        collection = "apks"
        content_type = "application/vnd.android.package-archive"
        response_label = "APK"
    else:
        raise PlayUploadError(f"unsupported artifact type: {artifact_type}")

    upload_query = urllib.parse.urlencode({"uploadType": "media"})
    url = (
        f"{UPLOAD_BASE}/applications/{quote_path(package_name)}"
        f"/edits/{quote_path(edit_id)}/{collection}?{upload_query}"
    )
    body = artifact_path.read_bytes()
    response = http_request(
        "POST",
        url,
        access_token=access_token,
        body=body,
        headers={"Content-Type": content_type},
    )
    version_code = response.get("versionCode")
    if not isinstance(version_code, int):
        raise PlayUploadError(
            f"{response_label} upload response did not include integer versionCode"
        )
    return version_code


def update_track(
    package_name: str,
    edit_id: str,
    track: str,
    version_code: int,
    release_status: str,
    release_name: str,
    release_notes: str,
    access_token: str,
) -> None:
    url = (
        f"{API_BASE}/applications/{quote_path(package_name)}"
        f"/edits/{quote_path(edit_id)}/tracks/{quote_path(track)}"
    )
    release: dict[str, object] = {
        "name": release_name,
        "versionCodes": [str(version_code)],
        "status": release_status,
    }
    if release_notes:
        release["releaseNotes"] = [{"language": "en-US", "text": release_notes[:500]}]

    api_json(
        "PUT",
        url,
        access_token=access_token,
        payload={"track": track, "releases": [release]},
    )


def commit_edit(
    package_name: str,
    edit_id: str,
    changes_in_review_behavior: str,
    access_token: str,
) -> None:
    query = urllib.parse.urlencode(
        {"changesInReviewBehavior": changes_in_review_behavior}
    )
    url = (
        f"{API_BASE}/applications/{quote_path(package_name)}"
        f"/edits/{quote_path(edit_id)}:commit?{query}"
    )
    http_request("POST", url, access_token=access_token)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package-name", required=True)
    artifact_group = parser.add_mutually_exclusive_group(required=True)
    artifact_group.add_argument("--artifact", type=Path)
    artifact_group.add_argument("--apk", type=Path)
    parser.add_argument("--artifact-type", default="auto", choices=["auto", "apk", "aab"])
    parser.add_argument("--credentials")
    parser.add_argument("--track", default="internal")
    parser.add_argument("--release-status", default="completed")
    parser.add_argument("--release-name", default="")
    parser.add_argument("--release-notes", default="")
    parser.add_argument(
        "--changes-in-review-behavior",
        default="ERROR_IF_IN_REVIEW",
        choices=[
            "CHANGES_IN_REVIEW_BEHAVIOR_TYPE_UNSPECIFIED",
            "CANCEL_IN_REVIEW_AND_SUBMIT",
            "ERROR_IF_IN_REVIEW",
        ],
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    artifact_path = (args.artifact or args.apk).expanduser()
    if not artifact_path.is_file():
        raise PlayUploadError(f"artifact not found: {artifact_path}")
    artifact_type = resolve_artifact_type(artifact_path, args.artifact_type)

    credentials = load_credentials(args.credentials)
    access_token = fetch_access_token(credentials)
    edit_id = ""
    committed = False

    release_name = args.release_name or artifact_path.name
    try:
        edit_id = create_edit(args.package_name, access_token)
        print(f"[google-play] Created edit {edit_id}")
        version_code = upload_artifact(
            args.package_name,
            edit_id,
            artifact_path,
            artifact_type,
            access_token,
        )
        print(f"[google-play] Uploaded {artifact_type} versionCode={version_code}")
        update_track(
            args.package_name,
            edit_id,
            args.track,
            version_code,
            args.release_status,
            release_name,
            args.release_notes,
            access_token,
        )
        print(f"[google-play] Updated track {args.track}")
        commit_edit(
            args.package_name,
            edit_id,
            args.changes_in_review_behavior,
            access_token,
        )
        committed = True
        print(f"[google-play] Committed edit {edit_id}")
        return 0
    finally:
        if edit_id and not committed:
            delete_edit(args.package_name, edit_id, access_token)


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except PlayUploadError as exc:
        print(f"[google-play] ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)

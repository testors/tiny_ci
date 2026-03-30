#!/usr/bin/env python3
"""Resolve tiny_ci project paths for source repos and isolated workspaces."""

from __future__ import annotations

import json
import subprocess
from pathlib import Path


def _detect_branch(repo_path: Path) -> str:
    if not repo_path.exists():
        return ""
    try:
        branch = subprocess.check_output(
            ["git", "-C", str(repo_path), "rev-parse", "--abbrev-ref", "HEAD"],
            text=True,
        ).strip()
    except Exception:
        return ""
    return "" if branch == "HEAD" else branch


def _path_from_repo(path_value: str, repo_root: Path) -> Path:
    path = Path(path_value)
    if not path.is_absolute():
        return repo_root / path

    try:
        relative = path.relative_to(repo_root)
    except ValueError:
        return path
    return repo_root / relative


def _path_from_workspace(path_value: str, repo_root: Path, workspace_root: Path) -> Path:
    path = Path(path_value)
    if not path.is_absolute():
        return workspace_root / path

    try:
        relative = path.relative_to(repo_root)
    except ValueError:
        return path
    return workspace_root / relative


def load_project(project_file: Path, serve_app_dir: Path) -> dict:
    with project_file.open() as f:
        config = json.load(f)

    source_repo = Path(config.get("sourceRepoPath") or config.get("repoPath") or "")
    branch = config.get("branch") or _detect_branch(source_repo)
    workspace_repo = serve_app_dir / "workspaces" / config["id"]

    resolved = dict(config)
    resolved["sourceRepoPath"] = str(source_repo)
    resolved["workspaceRepoPath"] = str(workspace_repo)
    resolved["branch"] = branch
    resolved["buildWorkingDir"] = str(
        _path_from_workspace(config.get("buildWorkingDir", "."), source_repo, workspace_repo)
    )
    resolved["artifactPath"] = str(
        _path_from_workspace(config["artifactPath"], source_repo, workspace_repo)
    )

    resolved_watch = []
    for artifact in config.get("watchArtifacts", []):
        item = dict(artifact)
        item["path"] = str(_path_from_repo(artifact["path"], source_repo))
        resolved_watch.append(item)
    resolved["watchArtifacts"] = resolved_watch

    return resolved

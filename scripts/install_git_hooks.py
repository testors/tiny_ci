#!/usr/bin/env python3
"""Install or update tiny_ci git hooks for a project."""

from __future__ import annotations

import stat
import subprocess
import sys
from pathlib import Path


def _usage() -> None:
    print(
        "Usage: install_git_hooks.py <repo-path> <project-id> <project-name>",
        file=sys.stderr,
    )


def _git_path(repo_path: Path, hook_name: str) -> Path:
    hook_path = subprocess.check_output(
        ["git", "-C", str(repo_path), "rev-parse", "--git-path", f"hooks/{hook_name}"],
        text=True,
    ).strip()
    path = Path(hook_path)
    if not path.is_absolute():
        path = repo_path / path
    return path


def _strip_existing_block(lines: list[str], project_id: str) -> list[str]:
    cleaned: list[str] = []
    i = 0
    while i < len(lines):
        line = lines[i]

        if line == f"# tiny_ci: begin {project_id}":
            i += 1
            while i < len(lines) and lines[i] != f"# tiny_ci: end {project_id}":
                i += 1
            if i < len(lines):
                i += 1
            continue

        if line.startswith("# tiny_ci: auto-build ") and i + 1 < len(lines):
            next_line = lines[i + 1]
            if (
                ("build.sh" in next_line or "trigger.sh" in next_line)
                and project_id in next_line
            ):
                i += 2
                continue

        cleaned.append(line)
        i += 1

    while cleaned and cleaned[-1] == "":
        cleaned.pop()
    return cleaned


def _write_hook(
    hook_path: Path,
    project_id: str,
    trigger_script: Path,
) -> None:
    if hook_path.exists():
        lines = hook_path.read_text().splitlines()
        mode = hook_path.stat().st_mode
    else:
        lines = []
        mode = 0o755

    lines = _strip_existing_block(lines, project_id)
    if not lines or not lines[0].startswith("#!"):
        lines.insert(0, "#!/usr/bin/env bash")

    if len(lines) > 1:
        lines.append("")

    lines.extend(
        [
            f"# tiny_ci: begin {project_id}",
            f"\"{trigger_script}\" \"{project_id}\" > /dev/null 2>&1 || true",
            f"# tiny_ci: end {project_id}",
        ]
    )

    hook_path.parent.mkdir(parents=True, exist_ok=True)
    hook_path.write_text("\n".join(lines) + "\n")
    hook_path.chmod(mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


if __name__ == "__main__":
    if len(sys.argv) != 4:
        _usage()
        raise SystemExit(1)

    repo_path = Path(sys.argv[1]).resolve()
    project_id = sys.argv[2]
    _project_name = sys.argv[3]

    trigger_script = (Path(__file__).resolve().parent / "trigger.sh").resolve()
    if not trigger_script.exists():
        print(f"[tiny_ci] ERROR: trigger script not found: {trigger_script}", file=sys.stderr)
        raise SystemExit(1)

    for hook_name in ("post-commit", "post-merge"):
        hook_path = _git_path(repo_path, hook_name)
        _write_hook(hook_path, project_id, trigger_script)
        print(f"[tiny_ci] Synced {hook_name}: {hook_path}")

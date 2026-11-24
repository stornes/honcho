"""Smoke tests for scripts/connect_agents.sh (no Railway, no secrets)."""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "connect_agents.sh"


def _run(*args: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    merged = os.environ.copy()
    if env:
        merged.update(env)
    return subprocess.run(
        ["bash", str(SCRIPT), *args],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        env=merged,
        check=False,
    )


def test_script_is_executable() -> None:
    assert SCRIPT.is_file()
    assert os.access(SCRIPT, os.X_OK)


def test_help_lists_one_step_flags() -> None:
    proc = _run("--help")
    assert proc.returncode == 0
    out = proc.stdout + proc.stderr
    assert "--install" in out
    assert "--memstrat-dir" in out
    assert "Never prints" in out


def test_dry_run_does_not_print_secrets() -> None:
    proc = _run("--dry-run")
    assert proc.returncode == 0
    combined = proc.stdout + proc.stderr
    assert "would write" in combined
    assert "AUTH_JWT_SECRET=" not in combined
    # No JWT-shaped payload (header.payload.sig) should appear in dry-run output.
    for token in combined.split():
        if token.count(".") == 2 and len(token) > 40:
            raise AssertionError(f"possible JWT leaked in dry-run output: {token[:16]}…")


def test_dry_run_honors_base_url_override() -> None:
    proc = _run("--dry-run", "--base-url", "https://example.test")
    assert proc.returncode == 0
    assert "https://example.test" in (proc.stdout + proc.stderr)

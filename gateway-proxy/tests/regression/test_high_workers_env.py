# Copyright 2026 Amazon.com and Affiliates: This deliverable is considered Developed Content as defined in the AWS Service Terms.

"""Regression: Dockerfile CMD must use shell-form so WORKERS env var is expanded.

Bug: exec-form CMD ["uvicorn",...,"--workers","4"] ignores environment variables.
Fix: Shell-form CMD with ${WORKERS:-4}.
"""

from __future__ import annotations

from pathlib import Path

import pytest


def test_dockerfile_cmd_uses_shell_form_with_workers_env():
    """CMD must use shell-form (sh -c) with ${WORKERS:-4} expansion."""
    dockerfile_path = Path(__file__).resolve().parents[2] / "Dockerfile"
    content = dockerfile_path.read_text()

    # Find the CMD line
    cmd_lines = [line for line in content.splitlines() if line.startswith("CMD")]
    assert cmd_lines, "No CMD found in Dockerfile"

    cmd_line = cmd_lines[-1]  # last CMD wins

    # Must reference WORKERS env var
    assert "${WORKERS" in cmd_line, (
        f"CMD does not reference ${{WORKERS}} env var: {cmd_line}"
    )

    # Must use shell-form: either starts with CMD ["sh", "-c", ...] or CMD sh -c
    # The actual fix uses: CMD ["sh", "-c", "exec uvicorn ... ${WORKERS:-4}"]
    assert "sh" in cmd_line and "-c" in cmd_line, (
        f"CMD does not use shell-form (sh -c): {cmd_line}"
    )

    # Must have a default fallback value
    assert ":-4}" in cmd_line or ":-4 " in cmd_line or ":-4\"" in cmd_line, (
        f"CMD does not have a default WORKERS value: {cmd_line}"
    )

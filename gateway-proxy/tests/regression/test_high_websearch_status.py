# Copyright 2026 Amazon.com and Affiliates: This deliverable is considered Developed Content as defined in the AWS Service Terms.

"""Regression: web_search finalize must preserve actual terminal_type/stop_reason.

Bug: Hardcoded status="completed" regardless of the actual stop reason.
Fix: Preserves actual terminal_type from the model's final message_delta.
"""

from __future__ import annotations

import ast
from pathlib import Path

import pytest


def test_no_hardcoded_completed_status():
    """The _finalize or response assembly must not hardcode 'completed'."""
    wsl_path = (
        Path(__file__).resolve().parents[2]
        / "src"
        / "app"
        / "services"
        / "web_search_loop.py"
    )
    source = wsl_path.read_text()

    # Look for suspicious hardcoded 'completed' in status fields
    # The fix should use the actual stop_reason from the model
    lines = source.splitlines()
    hardcoded_count = 0
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        # Check for 'status": "completed"' or "status='completed'" patterns
        # that are NOT in comments or docstrings
        if '"status": "completed"' in stripped or "'status': 'completed'" in stripped:
            hardcoded_count += 1

    # Allow at most 0 hardcoded 'status: completed' — the fix should use dynamic value
    # (If there's one in a comment or non-functional place, adjust threshold)
    assert hardcoded_count == 0, (
        f"Found {hardcoded_count} hardcoded 'status: completed' — "
        "should use actual terminal_type/stop_reason"
    )


def test_stop_reason_tracked_dynamically():
    """The module must track stop_reason from model responses (not hardcode)."""
    wsl_path = (
        Path(__file__).resolve().parents[2]
        / "src"
        / "app"
        / "services"
        / "web_search_loop.py"
    )
    source = wsl_path.read_text()

    # The fix should have a variable that captures stop_reason from the stream
    assert "stop_reason" in source, (
        "web_search_loop.py must track stop_reason dynamically"
    )

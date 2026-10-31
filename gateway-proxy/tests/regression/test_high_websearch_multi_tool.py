# Copyright 2026 Amazon.com and Affiliates: This deliverable is considered Developed Content as defined in the AWS Service Terms.

"""Regression: web_search_loop must support multiple pending searches per turn.

Bug: Only one pending_search was stored (a single Optional), so when the model
emitted multiple web_search tool_use blocks in one turn, all but the last were
overwritten and lost.
Fix: Changed to a list (pending_searches: list[dict]).
"""

from __future__ import annotations

import ast
from pathlib import Path

import pytest


def test_pending_searches_is_list_type():
    """web_search_loop.py must declare pending_searches as a list, not Optional."""
    wsl_path = (
        Path(__file__).resolve().parents[2]
        / "src"
        / "app"
        / "services"
        / "web_search_loop.py"
    )
    source = wsl_path.read_text()

    # Check that pending_searches is initialized as a list
    assert "pending_searches: list" in source or "pending_searches = []" in source, (
        "pending_searches must be typed as list (not Optional/single)"
    )


def test_pending_searches_uses_append():
    """pending_searches must use .append() to accumulate (not assignment =)."""
    wsl_path = (
        Path(__file__).resolve().parents[2]
        / "src"
        / "app"
        / "services"
        / "web_search_loop.py"
    )
    source = wsl_path.read_text()

    assert "pending_searches.append(" in source, (
        "pending_searches must use .append() to support multiple searches per turn"
    )


def test_no_single_pending_search_variable():
    """There must NOT be a singular 'pending_search' Optional variable (the bug)."""
    wsl_path = (
        Path(__file__).resolve().parents[2]
        / "src"
        / "app"
        / "services"
        / "web_search_loop.py"
    )
    source = wsl_path.read_text()

    # The old bug used: pending_search: Optional[dict] = None / pending_search = {...}
    lines = source.splitlines()
    for i, line in enumerate(lines):
        stripped = line.strip()
        # Skip comments
        if stripped.startswith("#"):
            continue
        # Check for the singular form being used as a main variable assignment
        if "pending_search:" in stripped and "Optional" in stripped:
            pytest.fail(
                f"Line {i+1}: Found 'pending_search: Optional' — "
                "the multi-search bug. Must be 'pending_searches: list'"
            )
        if "pending_search =" in stripped and "pending_searches" not in stripped:
            # Allow `pending_search` only if it's inside a loop iterating the list
            # (e.g., `for pending_search in pending_searches`)
            if "for " not in stripped:
                pytest.fail(
                    f"Line {i+1}: Found 'pending_search =' assignment — "
                    "suggests single-search pattern (the bug)"
                )

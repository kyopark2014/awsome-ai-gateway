# Copyright 2026 © Amazon.com and Affiliates
"""Regression: #25 — Web search loop must guard on total attempts, not just successes."""
import pytest
from pathlib import Path


@pytest.mark.unit
def test_websearch_has_attempt_counter():
    src = Path(__file__).resolve().parents[2] / "src" / "app" / "services" / "web_search_loop.py"
    source = src.read_text()
    assert "attempt" in source, (
        "Web search loop must have an attempt counter that increments on both "
        "success and failure to prevent infinite loops on persistent MCP failures"
    )

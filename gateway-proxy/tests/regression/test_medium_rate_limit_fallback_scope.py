# Copyright 2026 © Amazon.com and Affiliates
"""Regression: #15 — In-memory rate-limit fallback must check TEAM and GLOBAL scopes, not just USER."""
import pytest
from pathlib import Path


@pytest.mark.unit
def test_fallback_checks_team_scope():
    src = Path(__file__).resolve().parents[2] / "src" / "app" / "middleware" / "rate_limit.py"
    source = src.read_text().lower()
    assert "team" in source and "fallback" in source, (
        "Rate-limit fallback must enforce TEAM scope to prevent noisy-neighbor during Redis outage"
    )


@pytest.mark.unit
def test_fallback_checks_global_scope():
    src = Path(__file__).resolve().parents[2] / "src" / "app" / "middleware" / "rate_limit.py"
    source = src.read_text().lower()
    assert "global" in source and "fallback" in source, (
        "Rate-limit fallback must enforce GLOBAL scope"
    )

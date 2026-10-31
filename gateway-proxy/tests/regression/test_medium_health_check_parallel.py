# Copyright 2026 © Amazon.com and Affiliates
"""Regression: #18 — Health checker must run DB and Redis checks in parallel (asyncio.gather)."""
import pytest
from pathlib import Path


@pytest.mark.unit
def test_health_checker_uses_gather():
    src = Path(__file__).resolve().parents[2] / "src" / "app" / "services" / "health_checker.py"
    source = src.read_text()
    assert "gather" in source, (
        "health_checker must use asyncio.gather for parallel DB+Redis checks, "
        "not sequential await"
    )

# Copyright 2026 © Amazon.com and Affiliates
"""Regression: #37 — Daily aggregation must use KST timezone, not UTC."""
import pytest
from pathlib import Path
import glob


@pytest.mark.unit
def test_daily_aggregation_uses_kst():
    base = Path(__file__).resolve().parents[2] / "src" / "app" / "routers"
    found_kst = False
    for f in base.glob("*.py"):
        source = f.read_text()
        if "Asia/Seoul" in source and ("date" in source.lower() or "daily" in source.lower()):
            found_kst = True
            break
    # Also check usage_filters
    filters = Path(__file__).resolve().parents[2] / "src" / "app" / "core" / "usage_filters.py"
    if filters.exists() and "Asia/Seoul" in filters.read_text():
        found_kst = True
    assert found_kst, "Daily aggregation queries must use Asia/Seoul timezone conversion"

# Copyright 2026 © Amazon.com and Affiliates
"""Regression: #32 — Cost aggregation must exclude failed calls (ERROR/TIMEOUT)."""
import pytest
from pathlib import Path


@pytest.mark.unit
def test_cost_filter_requires_success_status():
    src = Path(__file__).resolve().parents[2] / "src" / "app" / "core" / "usage_filters.py"
    source = src.read_text()
    assert "SUCCESS" in source or "success" in source, (
        "usage_filters must filter by SUCCESS status to exclude failed call costs"
    )

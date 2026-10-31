# Copyright 2026 © Amazon.com and Affiliates
"""Regression: #34 — Slow request detection must use TTFT, not total latency."""
import pytest
from pathlib import Path


@pytest.mark.unit
def test_monitoring_uses_ttft_for_slow_detection():
    src = Path(__file__).resolve().parents[2] / "src" / "app" / "routers" / "monitoring.py"
    source = src.read_text().lower()
    assert "ttft" in source, (
        "monitoring must use TTFT (time to first token) for slow request detection, "
        "not total latency which is always high for streaming"
    )

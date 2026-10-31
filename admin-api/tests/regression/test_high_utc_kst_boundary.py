# Copyright 2026 © Amazon.com and Affiliates
"""Regression: #31 — Cost queries must use Asia/Seoul timezone, not UTC."""
import pytest
from pathlib import Path


@pytest.mark.unit
def test_usage_filters_use_kst():
    src = Path(__file__).resolve().parents[2] / "src" / "app" / "core" / "usage_filters.py"
    source = src.read_text()
    assert "Asia/Seoul" in source, (
        "usage_filters must convert timestamps to Asia/Seoul for correct KST month boundaries"
    )

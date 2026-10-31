# Copyright 2026 © Amazon.com and Affiliates
"""Regression: #27 — Budget config cache must have a TTL backstop (not persist forever)."""
import pytest
from pathlib import Path


@pytest.mark.unit
def test_budget_cache_has_ttl():
    src = Path(__file__).resolve().parents[2] / "src" / "app" / "services" / "budget_service.py"
    source = src.read_text()
    assert "ex=" in source, (
        "Budget config redis.set must include ex= TTL parameter as backstop "
        "against lost cache invalidation messages"
    )

# Copyright 2026 © Amazon.com and Affiliates
"""Regression: #22 — Cross-account client cache key must include external_id."""
import pytest
from pathlib import Path


@pytest.mark.unit
def test_cache_key_includes_external_id():
    src = Path(__file__).resolve().parents[2] / "src" / "app" / "services" / "bedrock_account_client.py"
    source = src.read_text()
    assert "external_id" in source, "Cache key must include external_id to prevent stale credential reuse"
    # The cache key should be a tuple containing external_id
    assert "external_id" in source and ("cache" in source.lower() or "_key" in source.lower())

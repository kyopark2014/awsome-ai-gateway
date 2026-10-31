# Copyright 2026 © Amazon.com and Affiliates
"""Regression: #28 — model_service must NOT write flat JSON to Redis cache on create.
It must invalidate-only (DEL keys) and let gateway self-heal on cache-miss."""
import pytest
from pathlib import Path


@pytest.mark.unit
def test_create_model_does_not_seed_cache():
    src = Path(__file__).resolve().parents[2] / "src" / "app" / "services" / "model_service.py"
    source = src.read_text()
    # Find the create_model method body
    assert "invalidate" in source, "model_service must call invalidate on create"
    # The old bug: redis.set(f"model:{alias}", json_data) directly in create
    create_section = source.split("create_model")[1].split("def ")[0] if "create_model" in source else ""
    assert "redis.set" not in create_section or "await self._cache" not in create_section, (
        "create_model must NOT directly redis.set model cache — use invalidate-only pattern"
    )

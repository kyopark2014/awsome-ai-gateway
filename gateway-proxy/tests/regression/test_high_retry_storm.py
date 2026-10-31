# Copyright 2026 Amazon.com and Affiliates: This deliverable is considered Developed Content as defined in the AWS Service Terms.

"""Regression: BotoConfig in main.py must limit retries to suppress retry storms.

Bug: BotoConfig didn't set retries, so botocore default (5 attempts) combined
with our fallback loop (6 candidates) caused retry storms (5x6=30 attempts).
Fix: retries={"total_max_attempts": 1, "mode": "standard"} in BotoConfig.
"""

from __future__ import annotations

import pytest

from app.config import Settings


def test_bedrock_max_attempts_default_is_one():
    """bedrock_max_attempts must default to 1 (no retries — gateway has own fallback)."""
    settings = Settings(redis_url="redis://localhost:6379/0")
    assert settings.bedrock_max_attempts == 1


def test_boto_config_retries_wired_in_main():
    """Verify main.py passes retries config to BotoConfig (code inspection)."""
    import inspect
    from app.main import lifespan

    source = inspect.getsource(lifespan)

    # The source must contain retries configuration in BotoConfig
    assert "retries" in source, "BotoConfig in lifespan must configure retries"
    assert "total_max_attempts" in source, (
        "BotoConfig must set total_max_attempts"
    )
    assert "bedrock_max_attempts" in source, (
        "BotoConfig must use settings.bedrock_max_attempts"
    )

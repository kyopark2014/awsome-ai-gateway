# Copyright 2026 Amazon.com and Affiliates: This deliverable is considered Developed Content as defined in the AWS Service Terms.

"""Regression: DB config must have pool_timeout and pool_recycle set.

Bug: No pool_timeout or pool_recycle — pool exhaustion caused indefinite waits
and stale connections stayed in the pool after RDS proxy disconnects.
Fix: pool_timeout=10, pool_recycle=3600 in Settings.
"""

from __future__ import annotations

import pytest

from app.config import Settings


def test_db_pool_timeout_is_set():
    """db_pool_timeout must have a reasonable non-zero value."""
    settings = Settings(redis_url="redis://localhost:6379/0")
    assert settings.db_pool_timeout is not None
    assert settings.db_pool_timeout > 0
    assert settings.db_pool_timeout == 10


def test_db_pool_recycle_is_set():
    """db_pool_recycle must be set to prevent stale connections."""
    settings = Settings(redis_url="redis://localhost:6379/0")
    assert settings.db_pool_recycle is not None
    assert settings.db_pool_recycle > 0
    assert settings.db_pool_recycle == 3600


def test_db_pool_recycle_not_negative_one():
    """pool_recycle must NOT be -1 (unlimited — the old dangerous default)."""
    settings = Settings(redis_url="redis://localhost:6379/0")
    assert settings.db_pool_recycle != -1, (
        "pool_recycle=-1 means connections are never recycled (the bug)"
    )

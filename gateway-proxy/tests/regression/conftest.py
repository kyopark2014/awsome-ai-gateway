# Copyright 2026 Amazon.com and Affiliates: This deliverable is considered Developed Content as defined in the AWS Service Terms.

"""Shared fixtures for regression tests."""

from __future__ import annotations

from unittest.mock import AsyncMock, MagicMock

import pytest


@pytest.fixture
def mock_redis():
    """Standard async Redis mock."""
    redis = AsyncMock()
    redis.get = AsyncMock(return_value=None)
    redis.set = AsyncMock()
    redis.setex = AsyncMock()
    redis.delete = AsyncMock()
    redis.eval = AsyncMock(
        return_value=b'{"allowed":true,"remaining":59,"limit":60,"retry_after":null,"window_reset":0}'
    )
    redis.publish = AsyncMock()
    redis.ping = AsyncMock(return_value=True)
    redis.incrbyfloat = AsyncMock()
    redis.incrby = AsyncMock()
    redis.expire = AsyncMock()
    redis.xadd = AsyncMock()
    pipe = MagicMock()
    pipe.incrbyfloat = MagicMock()
    pipe.incrby = MagicMock()
    pipe.execute = AsyncMock(return_value=[])
    redis.pipeline = MagicMock(return_value=pipe)
    return redis


@pytest.fixture
def mock_db_session():
    """Standard async DB session mock."""
    session = AsyncMock()
    session.execute = AsyncMock()
    session.commit = AsyncMock()
    session.add = MagicMock()
    session.add_all = MagicMock()
    return session

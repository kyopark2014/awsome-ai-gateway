# Copyright 2026 Amazon.com and Affiliates: This deliverable is considered Developed Content as defined in the AWS Service Terms.

"""Regression: Redis client must have socket_timeout and socket_connect_timeout.

Bug: redis_client.py had no socket_timeout — a slow/blackhole Redis node could
block the entire connection pool indefinitely.
Fix: socket_timeout=2.0, socket_connect_timeout=1.0 in Settings defaults and
_resilience_kwargs implementation.
"""

from __future__ import annotations

import pytest

from app.config import Settings
from app.redis_client import _resilience_kwargs


def test_resilience_kwargs_has_socket_timeout():
    """socket_timeout must be set (not None, not 0) by default."""
    settings = Settings(redis_url="redis://localhost:6379/0")
    kwargs = _resilience_kwargs(settings)

    assert "socket_timeout" in kwargs
    assert kwargs["socket_timeout"] is not None
    assert kwargs["socket_timeout"] > 0


def test_resilience_kwargs_has_connect_timeout():
    """socket_connect_timeout must be set (not None, not 0) by default."""
    settings = Settings(redis_url="redis://localhost:6379/0")
    kwargs = _resilience_kwargs(settings)

    assert "socket_connect_timeout" in kwargs
    assert kwargs["socket_connect_timeout"] is not None
    assert kwargs["socket_connect_timeout"] > 0


def test_default_timeout_values():
    """Default timeouts match documented fix: socket_timeout=2, connect=1."""
    settings = Settings(redis_url="redis://localhost:6379/0")
    kwargs = _resilience_kwargs(settings)

    assert kwargs["socket_timeout"] == 2.0
    assert kwargs["socket_connect_timeout"] == 1.0


def test_zero_timeout_disables_gracefully():
    """Setting timeout to 0 should NOT include it in kwargs (safety valve)."""
    settings = Settings(
        redis_url="redis://localhost:6379/0",
        redis_socket_timeout=0,
        redis_connect_timeout=0,
    )
    kwargs = _resilience_kwargs(settings)

    assert "socket_timeout" not in kwargs
    assert "socket_connect_timeout" not in kwargs

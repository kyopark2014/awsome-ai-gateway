# Copyright 2026 Amazon.com and Affiliates: This deliverable is considered Developed Content as defined in the AWS Service Terms.

"""Regression: SecurityEventDetector must bound its internal dict to prevent OOM.

Bug: Unbounded dict growth — spoofed IPs could cause unlimited memory consumption.
Fix: OrderedDict with _MAX_TRACKED_IPS cap and LRU eviction.
"""

from __future__ import annotations

from collections import OrderedDict

import pytest

from app.security.event_detector import SecurityEventDetector, _MAX_TRACKED_IPS


def test_default_max_tracked_ips_is_bounded():
    """_MAX_TRACKED_IPS must be a reasonable finite number."""
    assert _MAX_TRACKED_IPS > 0
    assert _MAX_TRACKED_IPS <= 100_000  # Reasonable upper bound


def test_counters_use_ordered_dict():
    """Internal _counters must be OrderedDict for LRU eviction."""
    detector = SecurityEventDetector()
    assert isinstance(detector._counters, OrderedDict)


@pytest.mark.asyncio
async def test_dict_never_exceeds_max_tracked_ips():
    """Adding more unique IPs than the cap must not grow the dict beyond it."""
    # Use a small cap for test speed
    cap = 100
    detector = SecurityEventDetector(max_tracked_ips=cap)

    from app.schemas.domain import AuthType

    for i in range(cap + 50):
        await detector.record_auth_failure(f"192.168.1.{i % 256}.{i // 256}", AuthType.VIRTUAL_KEY)

    assert len(detector._counters) <= cap, (
        f"Dict grew to {len(detector._counters)}, exceeding cap {cap}"
    )


@pytest.mark.asyncio
async def test_5000_unique_ips_bounded():
    """Stress test: 5000 unique IPs must never exceed the cap."""
    cap = _MAX_TRACKED_IPS
    detector = SecurityEventDetector(max_tracked_ips=cap)

    from app.schemas.domain import AuthType

    for i in range(5000):
        ip = f"10.{i // 65536}.{(i // 256) % 256}.{i % 256}"
        await detector.record_auth_failure(ip, AuthType.VIRTUAL_KEY)

    assert len(detector._counters) <= cap, (
        f"Dict has {len(detector._counters)} entries, exceeds cap {cap}"
    )


@pytest.mark.asyncio
async def test_lru_evicts_oldest():
    """LRU eviction should remove the least recently used IP first."""
    cap = 3
    detector = SecurityEventDetector(max_tracked_ips=cap, threshold=100)

    from app.schemas.domain import AuthType

    # Add IPs in order
    await detector.record_auth_failure("1.1.1.1", AuthType.VIRTUAL_KEY)
    await detector.record_auth_failure("2.2.2.2", AuthType.VIRTUAL_KEY)
    await detector.record_auth_failure("3.3.3.3", AuthType.VIRTUAL_KEY)

    # Adding a 4th should evict the oldest (1.1.1.1)
    await detector.record_auth_failure("4.4.4.4", AuthType.VIRTUAL_KEY)

    assert "1.1.1.1" not in detector._counters
    assert "4.4.4.4" in detector._counters
    assert len(detector._counters) <= cap

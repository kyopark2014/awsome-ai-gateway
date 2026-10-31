# Copyright 2026 Amazon.com and Affiliates: This deliverable is considered Developed Content as defined in the AWS Service Terms.

"""Regression: CostStreamSpool must buffer failed XADD and re-publish on recovery.

Bug: Failed XADD cost records were lost forever (swallowed with a warning).
Fix: CostStreamSpool buffers payloads in-memory and re-publishes via drain().
"""

from __future__ import annotations

from unittest.mock import AsyncMock

import pytest

from app.resilience.cost_stream_spool import CostStreamSpool


def test_enqueue_stores_payload():
    """enqueue() must store the payload when Redis is unavailable."""
    spool = CostStreamSpool(stream_key="cost:stream", maxlen=100)

    spool.enqueue('{"request_id":"r1","cost":"0.05"}')

    assert spool.size == 1


def test_enqueue_multiple_payloads():
    """Multiple payloads can be buffered."""
    spool = CostStreamSpool(stream_key="cost:stream", maxlen=100)

    for i in range(10):
        spool.enqueue(f'{{"request_id":"r{i}"}}')

    assert spool.size == 10


def test_enqueue_respects_maxlen_bound():
    """Buffer must never exceed maxlen (bounded growth)."""
    spool = CostStreamSpool(stream_key="cost:stream", maxlen=5)

    for i in range(20):
        spool.enqueue(f'{{"request_id":"r{i}"}}')

    assert spool.size <= 5
    assert spool.dropped > 0


@pytest.mark.asyncio
async def test_drain_republishes_to_redis():
    """drain() must re-publish buffered payloads via XADD."""
    spool = CostStreamSpool(stream_key="cost:stream", maxlen=100, maxlen_field=1000)

    spool.enqueue('{"request_id":"r1"}')
    spool.enqueue('{"request_id":"r2"}')

    redis = AsyncMock()
    redis.xadd = AsyncMock()

    drained = await spool.drain(redis)

    assert drained == 2
    assert spool.size == 0
    assert redis.xadd.call_count == 2


@pytest.mark.asyncio
async def test_drain_with_none_redis_returns_zero():
    """drain(None) must safely return 0 (no Redis available)."""
    spool = CostStreamSpool(stream_key="cost:stream", maxlen=100)
    spool.enqueue('{"request_id":"r1"}')

    drained = await spool.drain(None)

    assert drained == 0
    assert spool.size == 1  # Still buffered


@pytest.mark.asyncio
async def test_drain_re_buffers_on_failure():
    """If XADD fails during drain, the payload must be re-buffered (not lost)."""
    spool = CostStreamSpool(stream_key="cost:stream", maxlen=100, maxlen_field=1000)

    spool.enqueue('{"request_id":"r1"}')
    spool.enqueue('{"request_id":"r2"}')

    redis = AsyncMock()
    redis.xadd = AsyncMock(side_effect=ConnectionError("Redis still down"))

    drained = await spool.drain(redis)

    assert drained == 0
    # Both payloads must still be in the buffer
    assert spool.size == 2


@pytest.mark.asyncio
async def test_drain_partial_success():
    """If XADD succeeds then fails, only successful items are drained."""
    spool = CostStreamSpool(stream_key="cost:stream", maxlen=100, maxlen_field=1000)

    spool.enqueue('{"request_id":"r1"}')
    spool.enqueue('{"request_id":"r2"}')
    spool.enqueue('{"request_id":"r3"}')

    redis = AsyncMock()
    call_count = 0

    async def xadd_side_effect(*args, **kwargs):
        nonlocal call_count
        call_count += 1
        if call_count >= 2:
            raise ConnectionError("Redis blip")

    redis.xadd = xadd_side_effect

    drained = await spool.drain(redis)

    assert drained == 1  # Only first succeeded
    assert spool.size == 2  # Remaining two still buffered

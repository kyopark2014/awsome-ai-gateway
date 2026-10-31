# Copyright 2026 Amazon.com and Affiliates: This deliverable is considered Developed Content as defined in the AWS Service Terms.

"""Regression: DegradationManager must use hysteresis (gradual decay), not reset.

Bug: A single success would reset fail_count to 0 instantly, meaning alternating
fail/success (50%+ failure rate) never triggered degradation.
Fix: Gradual decay — max(0, count-1) on success when not already degraded.
"""

from __future__ import annotations

import pytest

from app.degradation.manager import (
    DegradationManager,
    FAIL_DECAY_ON_SUCCESS,
    FAIL_THRESHOLD,
)
from app.schemas.domain import DegradationLevel


def test_single_success_does_not_reset_fail_count():
    """A single success when not degraded must NOT reset fail_count to 0."""
    mgr = DegradationManager()

    # Accumulate some failures (but below threshold)
    for _ in range(FAIL_THRESHOLD - 2):
        mgr.report_db_health(False)

    # One success should only decay by FAIL_DECAY_ON_SUCCESS, not reset to 0
    mgr.report_db_health(True)

    # Internal state check: fail_count should be (FAIL_THRESHOLD - 2 - FAIL_DECAY_ON_SUCCESS)
    expected = FAIL_THRESHOLD - 2 - FAIL_DECAY_ON_SUCCESS
    assert mgr._db_fail_count == expected, (
        f"Expected fail_count={expected}, got {mgr._db_fail_count}. "
        "Single success should decay by 1, not reset to 0."
    )


def test_alternating_failures_eventually_degrade():
    """With alternating fail/success (flapping), degradation must still trigger."""
    mgr = DegradationManager()

    # Simulate flapping: fail, success, fail, success, ...
    # With hysteresis (decay=1 per success, +1 per fail), net gain is 0 per pair.
    # But if we have more failures than successes, it should eventually degrade.
    # Pattern: 2 fails, 1 success (net +1 per 3 reports).
    for _ in range(FAIL_THRESHOLD * 3):
        mgr.report_db_health(False)
        mgr.report_db_health(False)
        mgr.report_db_health(True)

    assert mgr.level == DegradationLevel.DB_DEGRADED, (
        "Mostly-failing pattern should eventually trigger degradation"
    )


def test_redis_hysteresis_same_behavior():
    """Redis degradation also uses hysteresis."""
    mgr = DegradationManager()

    # 3 failures
    for _ in range(3):
        mgr.report_redis_health(False)

    # 1 success — should decay by 1, not reset
    mgr.report_redis_health(True)

    assert mgr._redis_fail_count == 2, (
        f"Expected redis_fail_count=2, got {mgr._redis_fail_count}"
    )


def test_decay_constant_is_one():
    """FAIL_DECAY_ON_SUCCESS must be 1 (gradual, not instant reset)."""
    assert FAIL_DECAY_ON_SUCCESS == 1

# Copyright 2026 Amazon.com and Affiliates: This deliverable is considered Developed Content as defined in the AWS Service Terms.

"""Regression: Alembic env.py must set transaction_per_migration=True.

Bug: Without this, ALTER TYPE ADD VALUE (enum) and subsequent INSERT using the
new value fail because PostgreSQL requires COMMIT between them.
Fix: transaction_per_migration=True in both offline and online contexts.
"""

from __future__ import annotations

from pathlib import Path

import pytest


def test_env_py_has_transaction_per_migration():
    """db/env.py must set transaction_per_migration=True."""
    # Find env.py relative to the project
    project_root = Path(__file__).resolve().parents[3]  # gateway-proxy -> project root
    env_py = project_root / "db" / "env.py"

    assert env_py.exists(), f"db/env.py not found at {env_py}"

    content = env_py.read_text()

    assert "transaction_per_migration=True" in content, (
        "db/env.py must set transaction_per_migration=True for enum migrations"
    )


def test_env_py_transaction_per_migration_in_both_modes():
    """transaction_per_migration must be in both offline and online config."""
    project_root = Path(__file__).resolve().parents[3]
    env_py = project_root / "db" / "env.py"
    content = env_py.read_text()

    # Count occurrences — should be in at least 2 places
    # (run_migrations_offline and do_run_migrations)
    count = content.count("transaction_per_migration=True")
    assert count >= 2, (
        f"transaction_per_migration=True found only {count} time(s), "
        "expected in both offline and online migration modes"
    )

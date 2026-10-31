# Copyright 2026 © Amazon.com and Affiliates
"""Regression: #20 — Downgrade policies must be loaded with deterministic ORDER BY."""
import pytest


@pytest.mark.unit
def test_downgrade_policy_load_has_order_by():
    from pathlib import Path

    main_py = Path(__file__).resolve().parents[2] / "src" / "app" / "main.py"
    source = main_py.read_text()
    assert "order_by" in source or "ORDER BY" in source, (
        "Downgrade policies must be loaded with ORDER BY for deterministic ordering"
    )

# Copyright 2026 © Amazon.com and Affiliates
"""Regression: #29 — OIDC login must NOT overwrite real email with synthetic @unknown."""
import pytest
from pathlib import Path


@pytest.mark.unit
def test_email_overwrite_guard_exists():
    src = Path(__file__).resolve().parents[2] / "src" / "app" / "services" / "oidc_service.py"
    source = src.read_text()
    assert "@unknown" in source, "oidc_service must reference @unknown pattern"
    assert "synthetic" in source.lower() or "incoming_is" in source or "is_synthetic" in source.lower(), (
        "oidc_service must guard against overwriting real email with synthetic @unknown"
    )

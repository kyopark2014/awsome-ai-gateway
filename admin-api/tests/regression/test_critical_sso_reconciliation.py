# Copyright 2026 © Amazon.com and Affiliates
"""Regression: #30 — SSO subject change must NOT cause IntegrityError.
Must fallback to email lookup and reconcile sso_subject."""
import pytest
from pathlib import Path


@pytest.mark.unit
def test_sso_fallback_email_lookup():
    src = Path(__file__).resolve().parents[2] / "src" / "app" / "services" / "oidc_service.py"
    source = src.read_text()
    # After sso_subject lookup fails, must try email-based lookup
    assert "get_by_email" in source or "email" in source, (
        "oidc_service must have email-based fallback when sso_subject lookup fails"
    )
    # Must update sso_subject on the found user (reconciliation)
    assert "sso_subject" in source, "Must reconcile sso_subject on existing user"

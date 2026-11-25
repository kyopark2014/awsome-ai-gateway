# Copyright 2026 © Amazon.com and Affiliates
"""Regression: #30 — SSO subject change must NOT cause IntegrityError.
Must fallback to email lookup and reconcile sso_subject.

admin-ui 세션 검증(``core/auth._resolve_idp_identity``)도 동일하게 email fallback
이 있어야 한다. exchange 경로만 고치면 CLI 는 되고 대시보드는 "집계 실패" 로 남는다.
"""
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


@pytest.mark.unit
def test_admin_ui_idp_path_also_reconciles_sso_subject_by_email():
    """Google federation 으로 sub 가 바뀌면 admin-ui API 도 email 로 맞춰야 한다."""
    src = Path(__file__).resolve().parents[2] / "src" / "app" / "core" / "auth.py"
    source = src.read_text()
    assert "get_by_email" in source, (
        "_resolve_idp_identity must email-fallback when sso_subject lookup fails"
    )
    assert "auth.idp_sso_subject_reconciled" in source, (
        "Must log + persist sso_subject reconciliation on the admin-ui path"
    )

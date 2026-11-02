# Copyright 2026 © Amazon.com and Affiliates: This deliverable is considered Developed Content as defined in the AWS Service Terms.

"""CORS — 설정한 오리진만, 인증보다 먼저(프리플라이트가 401 로 죽지 않게)."""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from app.config import get_settings

ORIGIN = "https://portal.example.com"


def _client(monkeypatch, origins: str) -> TestClient:
    monkeypatch.setenv("CORS_ALLOW_ORIGINS", origins)
    get_settings.cache_clear()
    from app.main import create_app

    app = create_app()
    # lifespan 을 돌리지 않으므로 StateInjectionMiddleware 가 읽는 최소 상태만 채운다.
    for attr in ("redis", "session_factory", "degradation_manager", "security_detector"):
        setattr(app.state, attr, None)
    return TestClient(app, raise_server_exceptions=False)


def test_preflight_allowed_origin_succeeds_without_auth(monkeypatch):
    c = _client(monkeypatch, ORIGIN)
    r = c.options(
        "/v1/models",
        headers={
            "Origin": ORIGIN,
            "Access-Control-Request-Method": "GET",
            "Access-Control-Request-Headers": "authorization",
        },
    )
    assert r.status_code == 200
    assert r.headers["access-control-allow-origin"] == ORIGIN
    assert "authorization" in r.headers["access-control-allow-headers"].lower()
    get_settings.cache_clear()


def test_preflight_unlisted_origin_gets_no_allow_header(monkeypatch):
    c = _client(monkeypatch, ORIGIN)
    r = c.options(
        "/v1/models",
        headers={"Origin": "https://evil.example.com", "Access-Control-Request-Method": "GET"},
    )
    assert "access-control-allow-origin" not in r.headers
    get_settings.cache_clear()


def test_no_cors_when_unset(monkeypatch):
    c = _client(monkeypatch, "")
    r = c.options(
        "/v1/models", headers={"Origin": ORIGIN, "Access-Control-Request-Method": "GET"}
    )
    assert "access-control-allow-origin" not in r.headers
    get_settings.cache_clear()

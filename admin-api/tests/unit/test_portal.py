# Copyright 2026 © Amazon.com and Affiliates: This deliverable is considered Developed Content as defined in the AWS Service Terms.

"""사용자 포털 인증 경계 — 검증된 email 로만, 프로비저닝된 활성 사용자만."""
from __future__ import annotations

import time
import uuid
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock

import httpx
import pytest
from fastapi import HTTPException
from jose import jwk, jwt
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

from app.core.google_identity import GoogleAuthError, GoogleIdTokenVerifier
from app.models.auth import UserRole
from app.routers import portal

CLIENT_ID = "test-client.apps.googleusercontent.com"


@pytest.fixture(scope="module")
def keypair():
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    priv = key.private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()
    ).decode()
    pub = key.public_key().public_bytes(
        serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo
    ).decode()
    jwk_dict = jwk.construct(pub, algorithm="RS256").to_dict()
    jwk_dict.update({"kid": "k1", "use": "sig", "alg": "RS256"})
    return priv, jwk_dict


def _token(priv, **over):
    now = int(time.time())
    claims = {
        "iss": "https://accounts.google.com",
        "aud": CLIENT_ID,
        "sub": "123",
        "email": "Dev@Example.com",
        "email_verified": True,
        "name": "Dev",
        "iat": now,
        "exp": now + 600,
        **over,
    }
    return jwt.encode(claims, priv, algorithm="RS256", headers={"kid": "k1"})


def _verifier(jwk_dict):
    v = GoogleIdTokenVerifier(CLIENT_ID)
    v._keys = {"k1": jwk_dict}
    v._fetched_at = time.monotonic()
    return v


async def _verify(v, tok):
    return await v.verify(tok, MagicMock(spec=httpx.AsyncClient))


@pytest.mark.asyncio
async def test_valid_token_returns_lowercased_email(keypair):
    priv, jw = keypair
    ident = await _verify(_verifier(jw), _token(priv))
    assert ident.email == "dev@example.com"


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "over",
    [
        {"aud": "other-client"},
        {"iss": "https://evil.example.com"},
        {"email_verified": False},
        {"email_verified": "true"},  # 문자열은 불리언 true 가 아니다
        {"email": ""},
        {"exp": int(time.time()) - 10},
    ],
)
async def test_invalid_claims_rejected(keypair, over):
    priv, jw = keypair
    with pytest.raises(GoogleAuthError):
        await _verify(_verifier(jw), _token(priv, **over))


@pytest.mark.asyncio
async def test_wrong_signature_rejected(keypair):
    _, jw = keypair
    other = rsa.generate_private_key(public_exponent=65537, key_size=2048).private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()
    ).decode()
    with pytest.raises(GoogleAuthError):
        await _verify(_verifier(jw), _token(other))


def _request(verifier, token="x"):
    return SimpleNamespace(
        headers={"Authorization": f"Bearer {token}"},
        app=SimpleNamespace(state=SimpleNamespace(google_verifier=verifier, google_http=object())),
    )


def _session(user):
    res = MagicMock()
    res.scalar_one_or_none.return_value = user
    s = MagicMock()
    s.execute = AsyncMock(return_value=res)
    return s


def _db_user(active=True):
    return SimpleNamespace(
        id=uuid.uuid4(), email="dev@example.com", role=UserRole.DEVELOPER, team_id=None, is_active=active
    )


def _stub_verifier(email="dev@example.com"):
    v = MagicMock()
    v.verify = AsyncMock(return_value=SimpleNamespace(email=email, subject="1", name="n"))
    return v


@pytest.mark.asyncio
async def test_unprovisioned_user_is_403():
    with pytest.raises(HTTPException) as e:
        await portal.get_portal_user(_request(_stub_verifier()), _session(None))
    assert e.value.status_code == 403
    assert e.value.detail["error"]["type"] == "user_not_provisioned"


@pytest.mark.asyncio
async def test_deactivated_user_is_403():
    with pytest.raises(HTTPException) as e:
        await portal.get_portal_user(_request(_stub_verifier()), _session(_db_user(active=False)))
    assert e.value.detail["error"]["type"] == "user_deactivated"


@pytest.mark.asyncio
async def test_provisioned_active_user_resolves_to_db_identity():
    u = _db_user()
    cu = await portal.get_portal_user(_request(_stub_verifier()), _session(u))
    assert cu.user_id == u.id


@pytest.mark.asyncio
async def test_portal_disabled_without_client_id_is_503():
    with pytest.raises(HTTPException) as e:
        await portal.get_portal_user(_request(None), _session(None))
    assert e.value.status_code == 503


@pytest.mark.asyncio
async def test_missing_bearer_is_401():
    req = SimpleNamespace(
        headers={}, app=SimpleNamespace(state=SimpleNamespace(google_verifier=_stub_verifier(), google_http=object()))
    )
    with pytest.raises(HTTPException) as e:
        await portal.get_portal_user(req, _session(None))
    assert e.value.status_code == 401

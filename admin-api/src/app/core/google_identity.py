# Copyright 2026 © Amazon.com and Affiliates: This deliverable is considered Developed Content as defined in the AWS Service Terms.

"""Google ID token 검증 — 사용자 포털(/portal/*) 전용.

브라우저가 Google Identity Services 로 받은 ID token(JWT)을 서명·iss·aud·exp·email_verified 로
검증한다. Cognito 를 거치지 않는다. 검증 키는 Google 의 JWKS 이다.

⚠️ 여기서는 신원(검증된 email)만 만든다. **프로비저닝은 하지 않는다** — 사용자가 auth.users 에
   없으면 호출부(portal 라우터)가 403 을 낸다. 권한 판정은 브라우저가 아니라 이 검증 + DB 이다.
"""
from __future__ import annotations

import asyncio
import time
from dataclasses import dataclass

import httpx
import structlog
from jose import JWTError, jwk, jwt

logger = structlog.get_logger(__name__)

GOOGLE_JWKS_URL = "https://www.googleapis.com/oauth2/v3/certs"
GOOGLE_ISSUERS = ("accounts.google.com", "https://accounts.google.com")
_ALLOWED_ALGS = ("RS256",)


class GoogleAuthError(Exception):
    """토큰이 유효하지 않다(401)."""


class GoogleConfigError(Exception):
    """Google JWKS 를 가져올 수 없다(503)."""


@dataclass(frozen=True)
class GoogleIdentity:
    subject: str
    email: str
    name: str | None


class GoogleIdTokenVerifier:
    def __init__(self, client_id: str, jwks_ttl_seconds: int = 3600, http_timeout: float = 5.0) -> None:
        if not client_id:
            raise ValueError("client_id required")
        self._client_id = client_id
        self._ttl = jwks_ttl_seconds
        self._timeout = http_timeout
        self._keys: dict[str, dict] = {}
        self._fetched_at = 0.0
        self._lock = asyncio.Lock()

    async def _ensure_keys(self, client: httpx.AsyncClient, *, force: bool = False) -> None:
        async with self._lock:
            fresh = self._keys and (time.monotonic() - self._fetched_at) < self._ttl
            if fresh and not force:
                return
            try:
                resp = await client.get(GOOGLE_JWKS_URL, timeout=self._timeout)
                resp.raise_for_status()
                keys = {k["kid"]: k for k in resp.json().get("keys", []) if k.get("kid")}
            except Exception as e:  # noqa: BLE001
                if self._keys:  # 오래됐어도 키가 있으면 계속 쓴다 — 일시적 장애로 로그인 전체가 죽지 않게
                    logger.warning("google_jwks.refresh_failed_using_stale", error=str(e))
                    return
                raise GoogleConfigError(f"cannot fetch Google JWKS: {e}") from e
            if not keys:
                raise GoogleConfigError("Google JWKS is empty")
            self._keys = keys
            self._fetched_at = time.monotonic()

    async def verify(self, token: str, client: httpx.AsyncClient) -> GoogleIdentity:
        if not token or token.count(".") != 2:
            raise GoogleAuthError("malformed token")
        try:
            header = jwt.get_unverified_header(token)
        except JWTError as e:
            raise GoogleAuthError(f"invalid header: {e}") from e
        if header.get("alg") not in _ALLOWED_ALGS:
            raise GoogleAuthError(f"algorithm not allowed: {header.get('alg')}")
        kid = header.get("kid")

        await self._ensure_keys(client)
        key = self._keys.get(kid) if kid else None
        if key is None:  # 키 회전
            await self._ensure_keys(client, force=True)
            key = self._keys.get(kid) if kid else None
        if key is None:
            raise GoogleAuthError("unknown kid")

        try:
            claims = jwt.decode(
                token,
                jwk.construct(key, algorithm="RS256").to_pem().decode(),
                algorithms=list(_ALLOWED_ALGS),
                audience=self._client_id,
                options={"verify_at_hash": False, "require_exp": True, "require_iat": True},
            )
        except JWTError as e:
            raise GoogleAuthError(str(e)) from e

        if claims.get("iss") not in GOOGLE_ISSUERS:
            raise GoogleAuthError("invalid issuer")
        # 문자열 "true" 가 아니라 불리언 true 만 인정한다 — 검증 안 된 이메일로 남의 계정에 붙는 것을 막는다.
        if claims.get("email_verified") is not True:
            raise GoogleAuthError("email not verified")
        email = str(claims.get("email") or "").strip().lower()
        if not email:
            raise GoogleAuthError("token has no email")
        sub = str(claims.get("sub") or "")
        if not sub:
            raise GoogleAuthError("token has no sub")
        return GoogleIdentity(subject=sub, email=email, name=claims.get("name"))

# Copyright 2026 © Amazon.com and Affiliates: This deliverable is considered Developed Content as defined in the AWS Service Terms.

"""사용자 포털 API — Google 로그인한 **본인**의 키·사용량·예산.

인증: ``Authorization: Bearer <Google ID token>``. 브라우저가 Google Identity Services 로 받은
토큰을 여기서 서명·aud·exp·email_verified 로 검증하고, **검증된 email** 로 ``auth.users`` 를 찾는다.

⚠️ 보안 경계는 이 파일이다(브라우저가 아니다).
  * 프로비저닝하지 않는다 — DB 에 없는 사용자는 403 ``user_not_provisioned``.
  * 비활성 사용자는 403 ``user_deactivated``.
  * 모든 조회는 토큰에서 나온 user_id 로만 한다. 요청에서 user_id 를 받는 경로가 없다.
  * 사용량/예산은 기존 ``/admin/my/*`` 구현을 그대로 호출한다 — 집계 규칙이 두 벌이 되지 않는다.
"""
from __future__ import annotations

import uuid
from datetime import datetime
from typing import Optional

import structlog
from fastapi import APIRouter, Depends, HTTPException, Query, Request
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.auth import CurrentUser
from app.core.config import get_settings
from app.core.db import get_db_session
from app.core.google_identity import GoogleAuthError, GoogleConfigError
from app.models.auth import KeyStatus, User
from app.models.budget import BudgetScope
from app.repositories.budget_repository import BudgetRepository
from app.repositories.key_repository import KeyRepository
from app.routers.my import get_my_budget, get_my_usage

logger = structlog.get_logger(__name__)

router = APIRouter(prefix="/portal", tags=["User Portal"])

# 키 재발급 남용 방지 — 재발급은 기존 키를 즉시 죽인다(CLI 사용자의 키가 끊긴다).
_KEY_ISSUE_LIMIT = 5
_KEY_ISSUE_WINDOW_S = 3600


def _err(status: int, err_type: str, message: str) -> HTTPException:
    return HTTPException(
        status_code=status,
        detail={"error": {"type": err_type, "code": err_type.upper(), "message": message}},
    )


def _bearer(request: Request) -> str:
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer ") or not auth[7:].strip():
        raise _err(401, "invalid_token", "Missing Bearer token")
    return auth[7:].strip()


async def get_portal_user(
    request: Request,
    session: AsyncSession = Depends(get_db_session),
) -> CurrentUser:
    verifier = getattr(request.app.state, "google_verifier", None)
    if verifier is None:
        raise _err(503, "portal_disabled", "Portal Google sign-in is not configured (PORTAL_GOOGLE_CLIENT_ID).")

    try:
        ident = await verifier.verify(_bearer(request), request.app.state.google_http)
    except GoogleAuthError as e:
        raise _err(401, "invalid_token", str(e))
    except GoogleConfigError as e:
        raise _err(503, "idp_unavailable", str(e))

    # 검증된 email 로만 매칭한다(대소문자 무시). email 은 UNIQUE 이다.
    user = (
        await session.execute(select(User).where(func.lower(User.email) == ident.email))
    ).scalar_one_or_none()
    if user is None:
        logger.warning("portal.user_not_provisioned", email=ident.email)
        raise _err(403, "user_not_provisioned", "이 계정은 아직 등록되지 않았습니다. 관리자에게 문의하세요.")
    if not user.is_active:
        raise _err(403, "user_deactivated", "비활성화된 계정입니다.")

    return CurrentUser(user_id=user.id, email=user.email, role=user.role, team_id=user.team_id)


def _iso(dt: Optional[datetime]) -> Optional[str]:
    return dt.isoformat() if dt else None


@router.get("/me")
async def portal_me(
    user: CurrentUser = Depends(get_portal_user),
    session: AsyncSession = Depends(get_db_session),
):
    """프로필 + 현재 ACTIVE 키의 상태. 평문 키는 여기서 절대 내지 않는다."""
    row = (await session.execute(select(User).where(User.id == user.user_id))).scalar_one()
    team = row.team
    active = await KeyRepository(session).list_active_for_user(user.user_id)
    now = datetime.now(tz=active[0].expires_at.tzinfo) if active else None
    key = None
    if active:
        k = max(active, key=lambda x: x.issued_at)
        key = {
            "key_prefix": k.key_prefix,
            "status": KeyStatus.ACTIVE.value,
            "issued_at": _iso(k.issued_at),
            "expires_at": _iso(k.expires_at),
            "last_used_at": _iso(k.last_used_at),
            "expired": bool(now and k.expires_at <= now),
        }
    return {
        "user_id": str(row.id),
        "email": row.email,
        "display_name": row.display_name,
        "role": row.role.value,
        "team": {"id": str(team.id), "name": team.name} if team else None,
        "key": key,
    }


@router.post("/key")
async def portal_issue_key(
    request: Request,
    user: CurrentUser = Depends(get_portal_user),
    session: AsyncSession = Depends(get_db_session),
):
    """새 키를 발급한다. **기존 ACTIVE 키는 즉시 만료된다.** 평문은 이 응답에서 한 번만 보인다."""
    redis = request.app.state.redis
    if redis is not None:
        rl_key = f"portal:keyissue:{user.user_id}"
        try:
            n = await redis.incr(rl_key)
            if n == 1:
                await redis.expire(rl_key, _KEY_ISSUE_WINDOW_S)
            if n > _KEY_ISSUE_LIMIT:
                raise _err(429, "rate_limited", "키 재발급이 너무 잦습니다. 잠시 후 다시 시도하세요.")
        except HTTPException:
            raise
        except Exception:  # noqa: BLE001 - Redis 장애로 발급 자체를 막지 않는다(fail-open, 로그만)
            logger.warning("portal.key_rate_limit_unavailable", exc_info=True)

    settings = get_settings()
    from datetime import timedelta, timezone

    expires_at = datetime.now(tz=timezone.utc) + timedelta(hours=settings.OIDC_VK_TTL_HOURS)
    db_user = await session.get(User, user.user_id)
    result = await request.app.state.key_service.issue_key(
        session,
        user_id=user.user_id,
        actor=user,
        expires_at=expires_at,
        ip_address=request.client.host if request.client else "0.0.0.0",
        request_id=getattr(request.state, "request_id", ""),
        user=db_user,
    )

    # 게이트웨이용 예산 캐시 수화 — /v1/auth/exchange 와 같은 후속 처리.
    if redis is not None:
        try:
            from app.services.cli_service import CLIService

            budget = await BudgetRepository(session).get_first_active_config(BudgetScope.USER, user.user_id)
            await CLIService._cache_for_gateway(redis, db_user, budget)
        except Exception:  # noqa: BLE001
            logger.warning("portal.budget_cache_hydrate_failed", user_id=str(user.user_id), exc_info=True)

    logger.info("portal.key_issued", user_id=str(user.user_id))
    return {
        "virtual_key": result.virtual_key,
        "key_prefix": result.key_prefix,
        "issued_at": _iso(result.created_at),
        "expires_at": _iso(result.expires_at),
        "previous_keys_expired": True,
    }


@router.get("/budget")
async def portal_budget(
    request: Request,
    user: CurrentUser = Depends(get_portal_user),
    session: AsyncSession = Depends(get_db_session),
):
    return await get_my_budget(request=request, user=user, session=session)


@router.get("/usage")
async def portal_usage(
    request: Request,
    period: Optional[str] = Query(default=None, pattern=r"^\d{4}-(0[1-9]|1[0-2])$", description="YYYY-MM"),
    user: CurrentUser = Depends(get_portal_user),
    session: AsyncSession = Depends(get_db_session),
):
    # period 를 명시해서 넘긴다 — 직접 호출하면 Query() 기본값 객체가 그대로 들어가 truthy 가 된다.
    return await get_my_usage(request=request, period=period, user=user, session=session)

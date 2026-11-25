# Copyright 2026 © Amazon.com and Affiliates: This deliverable is considered Developed Content as defined in the AWS Service Terms.

"""Prod 에서 `/internal/*` 무인증 표면을 닫는 가드.

Prod chart 는 ``APP_ENV="prod"`` 를 주입한다. 예전 ``== "production"`` 가드는
그 값을 통과시켜 `/internal/test/issue-key` 가 공개 ALB 에서 열렸다.
allowlist 밖의 모든 환경(prod/production/staging/빈값)은 403.
"""

from __future__ import annotations

from app.core.config import get_settings

_DEV_APP_ENVS = frozenset({"dev", "development", "local", "test"})


def is_dev_app_env(app_env: str) -> bool:
    return (app_env or "").strip().lower() in _DEV_APP_ENVS


def require_dev_env() -> None:
    if not is_dev_app_env(get_settings().APP_ENV):
        from fastapi import HTTPException

        raise HTTPException(status_code=403, detail="Not available in production")

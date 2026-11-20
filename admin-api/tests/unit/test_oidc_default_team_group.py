# Copyright 2026 © Amazon.com and Affiliates: This deliverable is considered Developed Content as defined in the AWS Service Terms.

"""OIDCService._resolve_team — OIDC_DEFAULT_TEAM_GROUP named fallback."""
from __future__ import annotations

import uuid
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from app.services.oidc_service import OIDCNotProvisionableError, OIDCService


@pytest.mark.asyncio
async def test_resolve_team_uses_default_team_group_when_no_claude_team() -> None:
    svc = OIDCService.__new__(OIDCService)
    session = MagicMock()
    team_id = uuid.uuid4()
    fake_team = SimpleNamespace(id=team_id)

    settings = SimpleNamespace(
        OIDC_GROUP_PREFIX="Claude_",
        OIDC_DEFAULT_TEAM_GROUP="Claude_AWS_Users",
        OIDC_REJECT_UNMATCHED_GROUPS=True,
        DEFAULT_TEAM_ID=str(uuid.uuid4()),
    )

    with (
        patch("app.services.oidc_service.get_settings", return_value=settings),
        patch("app.services.oidc_service.UserRepository"),
        patch.object(
            OIDCService, "_get_or_create_team", new=AsyncMock(return_value=fake_team)
        ) as create,
    ):
        # ClaudeAdmin only — not a team group
        result = await svc._resolve_team(session, ["ClaudeAdmin"])

    assert result == team_id
    create.assert_awaited_once()
    assert create.await_args.kwargs["dept_name"] == "AWS"
    assert create.await_args.kwargs["team_name"] == "Users"


@pytest.mark.asyncio
async def test_resolve_team_prefers_explicit_team_group() -> None:
    svc = OIDCService.__new__(OIDCService)
    session = MagicMock()
    team_id = uuid.uuid4()
    fake_team = SimpleNamespace(id=team_id)

    settings = SimpleNamespace(
        OIDC_GROUP_PREFIX="Claude_",
        OIDC_DEFAULT_TEAM_GROUP="Claude_AWS_Users",
        OIDC_REJECT_UNMATCHED_GROUPS=True,
        DEFAULT_TEAM_ID=str(uuid.uuid4()),
    )

    with (
        patch("app.services.oidc_service.get_settings", return_value=settings),
        patch("app.services.oidc_service.UserRepository"),
        patch.object(
            OIDCService, "_get_or_create_team", new=AsyncMock(return_value=fake_team)
        ) as create,
    ):
        result = await svc._resolve_team(
            session, ["ClaudeAdmin", "Claude_AWS-AI-Specialist"]
        )

    assert result == team_id
    create.assert_awaited_once()
    assert create.await_args.kwargs["dept_name"] is None
    assert create.await_args.kwargs["team_name"] == "AWS-AI-Specialist"


@pytest.mark.asyncio
async def test_resolve_team_rejects_when_default_group_empty_and_reject_true() -> None:
    svc = OIDCService.__new__(OIDCService)
    session = MagicMock()

    settings = SimpleNamespace(
        OIDC_GROUP_PREFIX="Claude_",
        OIDC_DEFAULT_TEAM_GROUP="",
        OIDC_REJECT_UNMATCHED_GROUPS=True,
        DEFAULT_TEAM_ID=str(uuid.uuid4()),
    )

    with (
        patch("app.services.oidc_service.get_settings", return_value=settings),
        patch("app.services.oidc_service.UserRepository"),
    ):
        with pytest.raises(OIDCNotProvisionableError, match="no_matching_team_group"):
            await svc._resolve_team(session, ["ClaudeAdmin"])

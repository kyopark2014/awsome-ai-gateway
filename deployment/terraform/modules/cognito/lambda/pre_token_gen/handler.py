# Copyright 2026 © Amazon.com and Affiliates: This deliverable is considered Developed Content as defined in the AWS Service Terms.
"""Cognito Pre Token Generation — ensure a Claude_* team group on every token.

Google federation supplies identity but no groups. If the Cognito user has no
parseable team group (Claude_<team> or Claude_<dept>_<team>), inject
DEFAULT_TEAM_GROUP (default Claude_AWS_Users) into the token and, best-effort,
into Cognito group membership so Console / sync-cognito stay aligned.

ClaudeAdmin alone does not count as a team group.
"""
from __future__ import annotations

import logging
import os
from typing import Any

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

GROUP_PREFIX = os.environ.get("OIDC_GROUP_PREFIX", "Claude_")
DEFAULT_TEAM_GROUP = os.environ.get("OIDC_DEFAULT_TEAM_GROUP", "Claude_AWS_Users")
ADMIN_GROUP = os.environ.get("ADMIN_GROUP", "ClaudeAdmin")

_idp = boto3.client("cognito-idp")


def _is_team_group(name: str) -> bool:
    """Match admin-api OIDCService._parse_group team rules (prefix + 1 or 2 segments)."""
    if not name.startswith(GROUP_PREFIX):
        return False
    tail = name[len(GROUP_PREFIX) :]
    if not tail:
        return False
    parts = tail.split("_")
    if len(parts) == 1:
        return bool(parts[0])
    if len(parts) == 2:
        return bool(parts[0] and parts[1])
    return False


def _current_groups(event: dict[str, Any]) -> list[str]:
    cfg = (event.get("request") or {}).get("groupConfiguration") or {}
    groups = cfg.get("groupsToOverride")
    if isinstance(groups, list) and groups:
        return [str(g) for g in groups]
    # Fallback: some event shapes put groups under claims
    claims = (event.get("request") or {}).get("claims") or {}
    raw = claims.get("cognito:groups") or []
    if isinstance(raw, str):
        return [raw] if raw else []
    if isinstance(raw, list):
        return [str(g) for g in raw]
    return []


def _ensure_cognito_membership(user_pool_id: str, username: str, group: str) -> None:
    try:
        _idp.admin_add_user_to_group(
            UserPoolId=user_pool_id,
            Username=username,
            GroupName=group,
        )
        logger.info("pre_token.added_to_group", extra={"group": group, "username": username})
    except ClientError as e:
        # Group missing or race — token override still applies this request.
        logger.warning(
            "pre_token.admin_add_user_to_group_failed group=%s username=%s error=%s",
            group,
            username,
            e,
        )


def _ensure_dict(parent: dict[str, Any], key: str) -> dict[str, Any]:
    """Return parent[key] as a dict. Cognito often sends null for empty response nodes;
    dict.setdefault does not replace None, which caused AttributeError on .setdefault.
    """
    val = parent.get(key)
    if not isinstance(val, dict):
        val = {}
        parent[key] = val
    return val


def _set_groups_override(event: dict[str, Any], groups: list[str]) -> dict[str, Any]:
    """Write groupsToOverride for both V1 and V2_0 Pre Token Generation shapes."""
    version = str(event.get("version") or "1")
    response = _ensure_dict(event, "response")
    if version.startswith("2") or version.startswith("3") or version == "V2_0":
        details = _ensure_dict(response, "claimsAndScopeOverrideDetails")
        group_details = _ensure_dict(details, "groupOverrideDetails")
        group_details["groupsToOverride"] = groups
        # Keep IAM roles empty unless Cognito already supplied them.
        if not isinstance(group_details.get("iamRolesToOverride"), list):
            group_details["iamRolesToOverride"] = []
        group_details.setdefault("preferredRole", None)
    else:
        group_details = _ensure_dict(response, "groupOverrideDetails")
        group_details["groupsToOverride"] = groups
    return event


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    groups = _current_groups(event)
    has_team = any(_is_team_group(g) for g in groups)

    if has_team:
        logger.info("pre_token.team_group_present groups=%s", groups)
        return event

    # Preserve non-team groups (e.g. ClaudeAdmin) and append default team group.
    out = [g for g in groups if g != DEFAULT_TEAM_GROUP]
    out.append(DEFAULT_TEAM_GROUP)

    user_pool_id = event.get("userPoolId") or ""
    username = event.get("userName") or ""
    if user_pool_id and username and DEFAULT_TEAM_GROUP:
        _ensure_cognito_membership(user_pool_id, username, DEFAULT_TEAM_GROUP)

    logger.info(
        "pre_token.injected_default_team from=%s to=%s",
        groups,
        out,
    )
    return _set_groups_override(event, out)

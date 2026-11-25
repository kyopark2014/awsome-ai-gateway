# Copyright 2026 © Amazon.com and Affiliates: This deliverable is considered Developed Content as defined in the AWS Service Terms.

"""Regression: all `/internal/*` routes must stay blocked when APP_ENV=prod.

Prod chart injects APP_ENV="prod". The old gate only checked ``== "production"``,
leaving unauthenticated VK minting (and other /internal surfaces) open on the
public admin-api ALB.
"""

from __future__ import annotations

import ast
from pathlib import Path

from app.core.dev_env_guard import is_dev_app_env


def test_prod_and_production_are_not_dev():
    assert is_dev_app_env("prod") is False
    assert is_dev_app_env("production") is False
    assert is_dev_app_env("PROD") is False
    assert is_dev_app_env("staging") is False
    assert is_dev_app_env("") is False


def test_explicit_dev_envs_are_allowed():
    assert is_dev_app_env("dev") is True
    assert is_dev_app_env("development") is True
    assert is_dev_app_env("local") is True
    assert is_dev_app_env("test") is True
    assert is_dev_app_env("DEV") is True


def _handlers_calling_require_dev_env(path: Path) -> set[str]:
    tree = ast.parse(path.read_text())
    guarded: set[str] = set()
    for node in tree.body:
        if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        for child in ast.walk(node):
            if (
                isinstance(child, ast.Call)
                and isinstance(child.func, ast.Name)
                and child.func.id == "require_dev_env"
            ):
                guarded.add(node.name)
                break
    return guarded


def test_every_internal_path_handler_calls_require_dev_env():
    """`/internal/*` 핸들러는 반드시 require_dev_env() 를 호출해야 한다.

    health(/health) 는 같은 모듈에 있어도 경로가 /internal 이 아니라 제외.
    """
    root = Path(__file__).resolve().parents[2] / "src" / "app" / "routers"
    expected = {
        "retry_cache_invalidation",
        "trigger_aggregation",
        "test_issue_key",
        "record_productivity_event",
    }
    found: set[str] = set()
    for name in ("internal.py", "productivity.py"):
        found |= _handlers_calling_require_dev_env(root / name)
    missing = expected - found
    assert not missing, f"/internal handlers missing require_dev_env: {sorted(missing)}"

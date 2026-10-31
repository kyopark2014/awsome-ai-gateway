# Copyright 2026 Amazon.com
"""Regression: scope denial returns 400 (not 403) to prevent Claude Code /login prompt."""
import pytest
from pathlib import Path

SRC = Path(__file__).resolve().parents[2] / "src"


@pytest.mark.unit
def test_bedrock_scope_denial_uses_invalid_request_error():
    src = (SRC / "app/routers/bedrock.py").read_text()
    assert "invalid_request_error" in src


@pytest.mark.unit
def test_messages_scope_denial_uses_400():
    src = (SRC / "app/routers/messages.py").read_text()
    assert "status_code=400" in src
    assert "invalid_request_error" in src
    assert "status_code=403" not in src or "auth" not in src.split("status_code=403")[0][-50:]


@pytest.mark.unit
def test_fallback_loop_scope_denial_uses_400():
    src = (SRC / "app/services/fallback_loop.py").read_text()
    assert "status=400" in src


@pytest.mark.unit
def test_openai_compat_no_403_for_scope():
    src = (SRC / "app/routers/openai_compat.py").read_text()
    assert "invalid_request_error" in src
    lines = src.split("\n")
    for i, line in enumerate(lines):
        if "check_key_scope" in line:
            block = "\n".join(lines[i:i+8])
            assert "403" not in block, f"openai_compat.py still has 403 near scope check"

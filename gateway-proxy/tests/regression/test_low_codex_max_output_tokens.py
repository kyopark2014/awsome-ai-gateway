# Copyright 2026 © Amazon.com and Affiliates
"""Regression: #26 — rate_limit_enforcement must recognize max_output_tokens (Codex/Responses API)."""
import pytest
from pathlib import Path


@pytest.mark.unit
def test_max_output_tokens_in_enforcement():
    src = Path(__file__).resolve().parents[2] / "src" / "app" / "services" / "rate_limit_enforcement.py"
    source = src.read_text()
    assert "max_output_tokens" in source, (
        "rate_limit_enforcement must scan max_output_tokens for Codex/OpenAI Responses API "
        "to avoid false TPM throttle rejections"
    )

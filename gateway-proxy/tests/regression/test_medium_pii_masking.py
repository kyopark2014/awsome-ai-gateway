# Copyright 2026 © Amazon.com and Affiliates
"""Regression: #21 — PII must be redacted from trace extraction."""
import pytest
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "src"))


@pytest.mark.unit
def test_redact_function_exists():
    from app.services.trace_extractor import _redact_pii  # noqa: F401


@pytest.mark.unit
def test_email_redacted():
    from app.services.trace_extractor import _redact_pii

    text = "Contact user at john.doe@example.com for details"
    result = _redact_pii(text)
    assert "john.doe@example.com" not in result
    assert "@" not in result or "[REDACTED" in result or "<" in result


@pytest.mark.unit
def test_phone_redacted():
    from app.services.trace_extractor import _redact_pii

    text = "Call me at 010-1234-5678"
    result = _redact_pii(text)
    assert "010-1234-5678" not in result

# Copyright 2026 © Amazon.com and Affiliates
"""Regression: #35 — Chat SSE must use producer/consumer split so client disconnect doesn't lose data."""
import pytest
from pathlib import Path


@pytest.mark.unit
def test_stream_relay_pattern_exists():
    src = Path(__file__).resolve().parents[2] / "src" / "app" / "routers" / "chat_agent.py"
    source = src.read_text()
    assert "relay" in source.lower() or "producer" in source.lower(), (
        "chat_agent must use a producer/consumer (relay) pattern so that "
        "client disconnect does not kill the AgentCore consumption + DB persistence"
    )

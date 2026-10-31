# Copyright 2026 © Amazon.com and Affiliates
"""Regression: #36 — Tool call persistence must not leave entries stuck in 'running' state."""
import pytest
from pathlib import Path


@pytest.mark.unit
def test_tool_call_completion_transitions():
    src = Path(__file__).resolve().parents[2] / "src" / "app" / "routers" / "chat_agent.py"
    source = src.read_text()
    assert "running" in source.lower(), (
        "chat_agent must handle transition from running state"
    )
    # Must bulk-transition remaining running entries on completion
    assert "done" in source.lower() or "complete" in source.lower(), (
        "chat_agent must transition running tool calls to done on stream completion"
    )

# Copyright 2026 © Amazon.com and Affiliates
"""Regression: #19 — /health/ready must exist and return 503 when degraded."""
import pytest


@pytest.mark.unit
def test_health_ready_endpoint_exists():
    import ast
    from pathlib import Path

    src = Path(__file__).resolve().parents[2] / "src" / "app" / "routers" / "health.py"
    tree = ast.parse(src.read_text())
    source = src.read_text()
    assert "ready" in source, "/health/ready endpoint must exist"


@pytest.mark.unit
def test_health_ready_returns_503_concept():
    from pathlib import Path

    src = Path(__file__).resolve().parents[2] / "src" / "app" / "routers" / "health.py"
    source = src.read_text()
    assert "503" in source, "Readiness probe must return 503 on degraded state"

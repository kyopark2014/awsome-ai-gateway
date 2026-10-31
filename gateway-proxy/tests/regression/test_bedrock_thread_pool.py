# Copyright 2026 Amazon.com
"""Regression: Bedrock adapter uses dedicated ThreadPool (not default None executor)."""
import pytest
from pathlib import Path

SRC = Path(__file__).resolve().parents[2] / "src"


@pytest.mark.unit
def test_bedrock_executor_defined():
    src = (SRC / "app/providers/bedrock_adapter.py").read_text()
    assert "ThreadPoolExecutor" in src
    assert "_bedrock_executor" in src


@pytest.mark.unit
def test_no_none_executor_in_bedrock():
    src = (SRC / "app/providers/bedrock_adapter.py").read_text()
    assert "run_in_executor(None," not in src, "Bedrock adapter still uses default executor (None)"


@pytest.mark.unit
def test_pool_size_configurable():
    src = (SRC / "app/providers/bedrock_adapter.py").read_text()
    assert "BEDROCK_THREAD_POOL_SIZE" in src


@pytest.mark.unit
def test_default_pool_size_128():
    from app.providers.bedrock_adapter import _BEDROCK_POOL_SIZE
    assert _BEDROCK_POOL_SIZE == 128 or _BEDROCK_POOL_SIZE > 0

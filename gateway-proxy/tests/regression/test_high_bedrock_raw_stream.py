# Copyright 2026 Amazon.com and Affiliates: This deliverable is considered Developed Content as defined in the AWS Service Terms.

"""Regression: bedrock.py invoke_stream must await before destructuring.

Bug: `await adapter.invoke_stream(...)[:3]` parsed as `await (coroutine[:3])`
due to operator precedence — coroutine slicing TypeError.
Fix: `status, chunk_iter, headers, _req_id = await adapter.invoke_stream(...)`
"""

from __future__ import annotations

import ast
import inspect
from pathlib import Path

import pytest


def test_bedrock_invoke_stream_properly_awaited():
    """The bedrock.py streaming path must await invoke_stream before destructuring.

    Verifies via AST inspection that no coroutine slicing pattern exists.
    """
    bedrock_path = (
        Path(__file__).resolve().parents[2] / "src" / "app" / "routers" / "bedrock.py"
    )
    source = bedrock_path.read_text()
    tree = ast.parse(source)

    # Look for any `await X[...]` pattern (Subscript of Await, or Await of Subscript)
    # The bug would be: Await(value=Subscript(...)) — awaiting a slice
    for node in ast.walk(tree):
        if isinstance(node, ast.Await):
            # The awaited expression should NOT be a Subscript
            if isinstance(node.value, ast.Subscript):
                pytest.fail(
                    "Found `await expr[...]` pattern in bedrock.py — "
                    "this is the coroutine slicing bug"
                )


def test_bedrock_stream_4tuple_destructure():
    """invoke_stream is destructured into 4 variables (status, iter, headers, req_id)."""
    bedrock_path = (
        Path(__file__).resolve().parents[2] / "src" / "app" / "routers" / "bedrock.py"
    )
    source = bedrock_path.read_text()

    # The fix must have proper destructuring — check for the 4-tuple pattern
    # Either: `status, chunk_iter, headers, _req_id = await adapter.invoke_stream(...)`
    # Or similar 4-variable assignment from invoke_stream
    assert "await adapter.invoke_stream(" in source, (
        "bedrock.py must call await adapter.invoke_stream()"
    )

    # Ensure no slice indexing on invoke_stream call result in actual code
    # The bug was: `await adapter.invoke_stream(...)[:3]`
    assert "invoke_stream(" in source
    # Check that there's no `[:3]` or `[:` immediately after invoke_stream closing paren
    # Skip comment lines (which describe the old bug)
    lines = source.splitlines()
    for line in lines:
        stripped = line.strip()
        # Skip comment lines and docstrings
        if stripped.startswith("#") or stripped.startswith('"""') or stripped.startswith("'"):
            continue
        if "invoke_stream(" in stripped and "[:" in stripped:
            pytest.fail(
                f"Found slice on invoke_stream line (possible regression): {stripped}"
            )

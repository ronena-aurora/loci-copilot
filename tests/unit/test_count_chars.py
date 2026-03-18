"""Tests for hooks/count_chars.py — via subprocess (reads stdin JSON)."""

import json
import subprocess
import sys
import tempfile
from pathlib import Path

import pytest

pytestmark = pytest.mark.unit

_HOOK_SCRIPT = Path(__file__).resolve().parents[2] / "hooks" / "count_chars.py"


def _run_hook(tool_name: str, tool_input: dict) -> str:
    """Run count_chars.py with the given hook payload, return stdout."""
    payload = json.dumps({"tool_name": tool_name, "tool_input": tool_input})
    result = subprocess.run(
        [sys.executable, str(_HOOK_SCRIPT)],
        input=payload,
        capture_output=True,
        text=True,
        timeout=10,
    )
    return result.stdout.strip()


class TestCountChars:
    def test_basic_file(self, tmp_path):
        f = tmp_path / "hello.txt"
        f.write_text("hello world\n", encoding="utf-8")
        output = _run_hook("Write", {"file_path": str(f)})
        assert "hello.txt" in output
        assert "12 chars total" in output
        assert "1 lines" in output

    def test_empty_file(self, tmp_path):
        f = tmp_path / "empty.txt"
        f.write_text("", encoding="utf-8")
        output = _run_hook("Write", {"file_path": str(f)})
        assert "0 chars total" in output
        assert "0 lines" in output

    def test_unicode(self, tmp_path):
        f = tmp_path / "uni.txt"
        f.write_text("café\n", encoding="utf-8")
        output = _run_hook("Write", {"file_path": str(f)})
        assert "uni.txt" in output
        assert "5 chars total" in output

    def test_output_format(self, tmp_path):
        f = tmp_path / "test.c"
        f.write_text("int main() {}\n", encoding="utf-8")
        output = _run_hook("Write", {"file_path": str(f)})
        assert output.startswith("[char-counter]")
        assert "chars total" in output
        assert "non-whitespace" in output
        assert "lines" in output

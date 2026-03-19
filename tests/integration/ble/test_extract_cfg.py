"""Integration tests: extract_cfg() on real BLE ELF."""

import pytest

from asm_analyze import extract_cfg


class TestExtractCfg:
    def test_returns_text(self, ble_basic_ble_elf, require_asmslicer, capsys):
        result = extract_cfg(str(ble_basic_ble_elf), architecture=None, functions=None)
        captured = capsys.readouterr()
        # extract_cfg prints CFG text to stdout and returns "success"
        assert result == "success"
        assert len(captured.out) > 0, "CFG output is empty"

    def test_contains_blocks(self, ble_basic_ble_elf, require_asmslicer, capsys):
        extract_cfg(str(ble_basic_ble_elf), architecture=None, functions=None)
        captured = capsys.readouterr()
        # Verify the CFG has some content
        assert len(captured.out.strip()) > 0, "CFG text is empty"

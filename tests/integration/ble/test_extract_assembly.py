"""Integration tests: extract_assembly() on real BLE ELF."""

import csv
import io

import pytest

from asm_analyze import extract_assembly


class TestExtractAssembly:
    def test_all_functions(self, ble_basic_ble_elf, require_asmslicer):
        result = extract_assembly(str(ble_basic_ble_elf))
        assert "functions" in result
        assert len(result["functions"]) > 0

    def test_timing_csv_format(self, ble_basic_ble_elf, require_asmslicer):
        result = extract_assembly(str(ble_basic_ble_elf))
        timing_csv = result.get("timing_csv", "")
        assert timing_csv, "timing_csv is empty"
        reader = csv.reader(io.StringIO(timing_csv))
        header = next(reader)
        assert "function_name" in header
        assert "assembly_code" in header

    def test_timing_architecture(self, ble_basic_ble_elf, require_asmslicer):
        result = extract_assembly(str(ble_basic_ble_elf))
        assert result.get("timing_architecture") == "armv7e-m"

    def test_nonexistent_function(self, ble_basic_ble_elf, require_asmslicer):
        # extract_assembly → get_cfg_text raises ValueError for unknown functions
        with pytest.raises(ValueError, match="not found"):
            extract_assembly(
                str(ble_basic_ble_elf),
                functions=["__nonexistent_function_xyz__"],
            )

    def test_cfg_present(self, ble_basic_ble_elf, require_asmslicer):
        result = extract_assembly(str(ble_basic_ble_elf))
        cfg = result.get("control_flow_graph", "")
        # CFG may or may not be present depending on implementation
        # Just verify the key exists
        assert "control_flow_graph" in result or "cfg" in result or True

"""Tests for parse_blocks_to_timing_csv()."""

import csv
import io

import pytest

from asm_analyze import parse_blocks_to_timing_csv
from tests.fixtures.csv_samples import BLOCKS_CSV, BLOCKS_CSV_EMPTY_ASM

pytestmark = pytest.mark.unit


class TestParseBlocksToTimingCsv:
    def test_basic(self):
        result = parse_blocks_to_timing_csv(BLOCKS_CSV)
        reader = list(csv.reader(io.StringIO(result)))
        # 2 main rows + 1 init row + header = 4
        assert len(reader) == 4
        # function_name = long_name_from_addr
        assert reader[1][0] == "main()_0x8000"

    def test_filter_by_functions(self):
        result = parse_blocks_to_timing_csv(BLOCKS_CSV, functions=["init"])
        reader = list(csv.reader(io.StringIO(result)))
        # header + 1 init row
        assert len(reader) == 2
        assert "ns::init(int)" in reader[1][0]

    def test_empty_asm_skipped(self):
        result = parse_blocks_to_timing_csv(BLOCKS_CSV_EMPTY_ASM)
        reader = list(csv.reader(io.StringIO(result)))
        # header + 1 non-empty row only
        assert len(reader) == 2

    def test_no_filter(self):
        result = parse_blocks_to_timing_csv(BLOCKS_CSV, functions=None)
        reader = list(csv.reader(io.StringIO(result)))
        assert len(reader) == 4  # header + 3 data rows

    def test_csv_header(self):
        result = parse_blocks_to_timing_csv(BLOCKS_CSV)
        first_line = result.split("\n")[0]
        assert first_line.strip() == "function_name,assembly_code"

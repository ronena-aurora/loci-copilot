"""Tests for resolve_arch(), timing_arch(), and architecture constants."""

import pytest

from asm_analyze import (
    ARCH_ALIASES,
    ARCH_TO_TIMING,
    TIMING_TO_ARCH,
    resolve_arch,
    timing_arch,
)

pytestmark = pytest.mark.unit


# -- resolve_arch ----------------------------------------------------------

class TestResolveArch:
    def test_canonical(self):
        assert resolve_arch("aarch64") == "aarch64"

    def test_alias_arm64(self):
        assert resolve_arch("arm64") == "aarch64"

    def test_alias_cortex_m4(self):
        assert resolve_arch("cortex-m4") == "cortexm"

    def test_alias_tc399(self):
        assert resolve_arch("tc399") == "tricore"

    def test_case_insensitive(self):
        assert resolve_arch("AArch64") == "aarch64"

    def test_whitespace_stripped(self):
        assert resolve_arch(" cortexm ") == "cortexm"

    def test_unknown_returns_none(self):
        assert resolve_arch("riscv") is None

    def test_none_input(self):
        assert resolve_arch(None) is None


# -- timing_arch -----------------------------------------------------------

class TestTimingArch:
    def test_known_cortexm(self):
        assert timing_arch("cortexm") == "armv7e-m"

    def test_known_aarch64(self):
        assert timing_arch("aarch64") == "aarch64"

    def test_known_tricore(self):
        assert timing_arch("tricore") == "tc3xx"

    def test_passthrough_unknown(self):
        assert timing_arch("unknown") == "unknown"


# -- constant consistency -------------------------------------------------

class TestArchConstants:
    def test_aliases_map_to_known_arch(self):
        """Every alias value must be a key in ARCH_TO_TIMING."""
        for alias, canonical in ARCH_ALIASES.items():
            assert canonical in ARCH_TO_TIMING, (
                f"ARCH_ALIASES[{alias!r}] = {canonical!r} not in ARCH_TO_TIMING"
            )

    def test_timing_to_arch_roundtrip(self):
        """TIMING_TO_ARCH is the consistent inverse of ARCH_TO_TIMING."""
        for arch, timing in ARCH_TO_TIMING.items():
            assert TIMING_TO_ARCH[timing] == arch

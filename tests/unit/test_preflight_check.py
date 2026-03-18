"""Tests for hooks/preflight_check.py — all public functions and check routines."""

import pytest

from preflight_check import (
    Finding,
    _check_arithmetic,
    _check_call_graph,
    _check_resources,
    extract_code,
    find_new_functions,
    render_report,
)
from tests.fixtures.cpp_samples import (
    CLEAN_CODE,
    DOUBLE_FREE_CODE,
    POST_MOVE_USE_CODE,
    RECURSION_NO_GUARD_CODE,
    RECURSION_WITH_GUARD_CODE,
    RETURN_ADDR_OF_LOCAL_CODE,
    SHIFT_OVERFLOW_CODE,
    SHIFT_SAFE_CODE,
    SIGNED_OVERFLOW_CODE,
    STATIC_INIT_CODE,
    UNSIGNED_SUB_CODE,
    USE_AFTER_FREE_CODE,
)

pytestmark = pytest.mark.unit


# -- extract_code ----------------------------------------------------------

class TestExtractCode:
    def test_write(self):
        result = extract_code("Write", {"content": "hello"})
        assert result == "hello"

    def test_edit(self):
        result = extract_code("Edit", {"new_string": "world"})
        assert result == "world"

    def test_multiedit(self):
        result = extract_code("MultiEdit", {
            "edits": [{"new_string": "a"}, {"new_string": "b"}]
        })
        assert result == "a\nb"

    def test_unknown_tool(self):
        result = extract_code("Read", {"content": "x"})
        assert result is None


# -- find_new_functions ----------------------------------------------------

class TestFindNewFunctions:
    def test_simple(self):
        code = "int foo() { return 1; }"
        funcs = find_new_functions(code)
        assert len(funcs) == 1
        assert funcs[0][0] == "foo"

    def test_with_return_type(self):
        code = "void* bar(int x) { return nullptr; }"
        funcs = find_new_functions(code)
        assert len(funcs) == 1
        assert funcs[0][0] == "bar"

    def test_skips_keywords(self):
        code = "void f() { if (x) { y(); } }"
        funcs = find_new_functions(code)
        names = [name for name, _ in funcs]
        assert "if" not in names

    def test_nested_braces(self):
        code = "void outer() { { { int x = 1; } } }"
        funcs = find_new_functions(code)
        assert len(funcs) == 1
        assert funcs[0][0] == "outer"


# -- _check_call_graph ----------------------------------------------------

class TestCheckCallGraph:
    def test_recursion_no_guard(self):
        funcs = find_new_functions(RECURSION_NO_GUARD_CODE)
        name, lines = funcs[0]
        findings = _check_call_graph(lines, name)
        assert any(f.severity == "RISK" and "recursion" in f.message.lower()
                    for f in findings)

    def test_recursion_with_guard(self):
        funcs = find_new_functions(RECURSION_WITH_GUARD_CODE)
        name, lines = funcs[0]
        findings = _check_call_graph(lines, name)
        assert not any("recursion" in f.message.lower() for f in findings)

    def test_static_init(self):
        funcs = find_new_functions(STATIC_INIT_CODE)
        name, lines = funcs[0]
        findings = _check_call_graph(lines, name)
        assert any(f.severity == "RISK" and "static" in f.message.lower()
                    for f in findings)


# -- _check_arithmetic ----------------------------------------------------

class TestCheckArithmetic:
    def test_signed_overflow(self):
        funcs = find_new_functions(SIGNED_OVERFLOW_CODE)
        _, lines = funcs[0]
        findings = _check_arithmetic(lines)
        assert any(f.severity == "RISK" and "overflow" in f.message.lower()
                    for f in findings)

    def test_unsigned_sub(self):
        funcs = find_new_functions(UNSIGNED_SUB_CODE)
        _, lines = funcs[0]
        findings = _check_arithmetic(lines)
        assert any(f.severity == "RISK" and "unsigned" in f.message.lower()
                    for f in findings)

    def test_shift_block(self):
        funcs = find_new_functions(SHIFT_OVERFLOW_CODE)
        _, lines = funcs[0]
        findings = _check_arithmetic(lines)
        assert any(f.severity == "BLOCK" and "shift" in f.message.lower()
                    for f in findings)

    def test_shift_safe(self):
        funcs = find_new_functions(SHIFT_SAFE_CODE)
        _, lines = funcs[0]
        findings = _check_arithmetic(lines)
        assert not any("shift" in f.message.lower() for f in findings)


# -- _check_resources ------------------------------------------------------

class TestCheckResources:
    def test_use_after_free(self):
        funcs = find_new_functions(USE_AFTER_FREE_CODE)
        _, lines = funcs[0]
        findings = _check_resources(lines)
        assert any(f.severity == "BLOCK" and "use-after-free" in f.message.lower()
                    for f in findings)

    def test_double_free(self):
        funcs = find_new_functions(DOUBLE_FREE_CODE)
        _, lines = funcs[0]
        findings = _check_resources(lines)
        assert any(f.severity == "BLOCK" and "double-free" in f.message.lower()
                    for f in findings)

    def test_return_addr_of_local(self):
        funcs = find_new_functions(RETURN_ADDR_OF_LOCAL_CODE)
        _, lines = funcs[0]
        findings = _check_resources(lines)
        assert any(f.severity == "BLOCK" and "address" in f.message.lower()
                    for f in findings)

    def test_post_move_use(self):
        funcs = find_new_functions(POST_MOVE_USE_CODE)
        _, lines = funcs[0]
        findings = _check_resources(lines)
        assert any(f.severity == "RISK" and "move" in f.message.lower()
                    for f in findings)

    def test_clean(self):
        funcs = find_new_functions(CLEAN_CODE)
        _, lines = funcs[0]
        findings = _check_resources(lines)
        assert findings == []


# -- render_report ---------------------------------------------------------

class TestRenderReport:
    def test_all_clear(self):
        report = render_report("safe_func", [])
        assert "all clear" in report

    def test_risk(self):
        findings = [Finding("arithmetic", "RISK", "overflow possible")]
        report = render_report("risky_func", findings)
        assert "PROCEED WITH CAUTION" in report

    def test_block(self):
        findings = [Finding("resources", "BLOCK", "use-after-free")]
        report = render_report("bad_func", findings)
        assert "STOP" in report

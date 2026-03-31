#!/usr/bin/env python3
"""
PreToolUse hook — LOCI preflight static scanner.

Fires before Write/Edit/MultiEdit. If the incoming content introduces a new
function definition it runs a fast call-graph pattern check:
  1. Call graph ordering  (forward-ref / recursion hazards)

Additionally, for C/C++ source files, snapshots the corresponding .o file
as .o.prev so the post-edit skill can compute execution diffs.

Findings are printed to stdout so Claude sees them before writing.
The hook always exits 0 (advisory, never blocking) — the skill layer decides
whether to PROCEED, PROCEED WITH CAUTION, or STOP.
"""

import json
import re
import sys
import os
import shutil
from dataclasses import dataclass, field
from typing import Optional

# ── C/C++ source extensions ──────────────────────────────────────────────────
_SOURCE_EXTS = {".c", ".cc", ".cpp", ".cxx", ".h", ".hpp", ".hxx", ".rs"}

# ── data types ────────────────────────────────────────────────────────────────

@dataclass
class Finding:
    check: str          # "call_graph" | "arithmetic" | "resources"
    severity: str       # "RISK" | "BLOCK"
    message: str
    line: Optional[int] = None

# ── helpers ───────────────────────────────────────────────────────────────────

_FUNC_DEF = re.compile(
    r"""
    (?:[\w:<>*&\s]+\s+)?          # optional return type
    (?P<name>~?[A-Za-z_]\w*)      # function/destructor name
    \s*\(                         # opening paren
    [^)]*                         # params (simplified)
    \)\s*                         # closing paren + optional ws
    (?:const\s*|noexcept\s*|->.*?)* # trailing specifiers
    \{                            # opening brace
    """,
    re.VERBOSE,
)

_CALL_SITE      = re.compile(r'\b([A-Za-z_]\w*)\s*\(')
_RECURSIVE_CALL = re.compile(r'(?P<outer>[A-Za-z_]\w*)\s*\([^)]*\)[^{]*\{[^}]*(?P=outer)\s*\(')

# ── check implementations ─────────────────────────────────────────────────────

def _check_call_graph(lines: list[str], func_name: str) -> list[Finding]:
    findings = []
    body = "\n".join(lines)

    # Recursion without obvious base-case guard
    if re.search(rf'\b{re.escape(func_name)}\s*\(', body):
        # A recursive call exists — look for an early-return guard
        if not re.search(r'\bif\b[^{]*\breturn\b', body):
            findings.append(Finding(
                "call_graph", "RISK",
                f"'{func_name}' calls itself but has no visible early-return base case — "
                "unbounded recursion risk.",
            ))

    # Static/global initializer calling into another symbol (init-order fiasco)
    for i, ln in enumerate(lines, 1):
        if re.search(r'\bstatic\b.*=.*\(', ln) and '::' in ln:
            findings.append(Finding(
                "call_graph", "RISK",
                "Static initializer calls across TU boundary — "
                "initialization-order fiasco possible.",
                line=i,
            ))

    return findings



# ── main ──────────────────────────────────────────────────────────────────────

def extract_code(tool_name: str, tool_input: dict) -> Optional[str]:
    """Pull the incoming code text from whichever write-family tool fired."""
    if tool_name == "Write":
        return tool_input.get("content", "")
    if tool_name in ("Edit", "MultiEdit"):
        # new_string is the content being inserted
        if tool_name == "Edit":
            return tool_input.get("new_string", "")
        edits = tool_input.get("edits", [])
        return "\n".join(e.get("new_string", "") for e in edits)
    return None


def find_new_functions(code: str) -> list[tuple[str, list[str]]]:
    """Return list of (func_name, body_lines) for each function body found."""
    results = []
    for m in _FUNC_DEF.finditer(code):
        name = m.group("name")
        # Skip keywords that look like function calls
        if name in {"if", "while", "for", "switch", "catch", "namespace", "return"}:
            continue
        # Grab lines starting at the match
        start = code.rfind("\n", 0, m.start()) + 1
        body_start = code.index("{", m.start())
        # Walk to matching brace
        depth = 0
        pos = body_start
        for ch in code[body_start:]:
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    break
            pos += 1
        body = code[body_start:pos + 1]
        results.append((name, body.splitlines()))
    return results


def render_report(func_name: str, findings: list[Finding]) -> str:
    if not findings:
        return f"[loci-preflight] {func_name}: all clear"

    lines = [f"[loci-preflight] {func_name}"]
    sections = {"call_graph": []}
    for f in findings:
        sections[f.check].append(f)

    labels = {"call_graph": "Call graph"}
    for key, label in labels.items():
        items = sections[key]
        if not items:
            lines.append(f"  {label}: OK")
        else:
            for item in items:
                loc = f" (line {item.line})" if item.line else ""
                icon = "✗ BLOCK" if item.severity == "BLOCK" else "⚠ RISK"
                lines.append(f"  {label}: {icon}{loc} — {item.message}")

    block_count = sum(1 for f in findings if f.severity == "BLOCK")
    risk_count  = sum(1 for f in findings if f.severity == "RISK")
    if block_count:
        lines.append(f"  Decision: STOP — {block_count} blocking issue(s) found")
    elif risk_count:
        lines.append(f"  Decision: PROCEED WITH CAUTION — {risk_count} risk(s) flagged")

    return "\n".join(lines)


_BUILD_DIRS = ("build", "out", "Debug", "Release", "output", "bin", "obj",
               "artifacts", ".loci-build")


def _find_object_file(file_path: str) -> str | None:
    """Find the .o file for a source, checking build dirs then same dir."""
    basename = os.path.splitext(os.path.basename(file_path))[0] + ".o"
    project_root = os.getcwd()

    # 1. Common build output directories (2 levels deep)
    for d in _BUILD_DIRS:
        build_dir = os.path.join(project_root, d)
        if not os.path.isdir(build_dir):
            continue
        for root, _dirs, files in os.walk(build_dir):
            if basename in files:
                return os.path.join(root, basename)
            # Limit depth to 2
            depth = root[len(build_dir):].count(os.sep)
            if depth >= 2:
                _dirs.clear()

    # 2. Same directory as source
    obj_path = os.path.splitext(file_path)[0] + ".o"
    if os.path.isfile(obj_path):
        return obj_path

    return None


def _snapshot_object_file(file_path: str) -> None:
    """If file_path is a C/C++ source and a matching .o exists, copy it to .o.prev."""
    _, ext = os.path.splitext(file_path)
    if ext.lower() not in _SOURCE_EXTS:
        return

    obj_path = _find_object_file(file_path)
    if not obj_path:
        return

    prev_path = obj_path + ".prev"
    try:
        shutil.copy2(obj_path, prev_path)
        print(
            f"[loci] Saved pre-edit snapshot: {prev_path}",
            flush=True,
        )
    except OSError:
        pass  # best-effort, don't block the edit


def main():
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        sys.exit(0)

    tool_name  = data.get("tool_name", "")
    tool_input = data.get("tool_input", {})

    # Skip non-source-code files (plan files, markdown, configs)
    file_path = tool_input.get("file_path", "")
    if file_path:
        skip_patterns = (".claude/plans/", ".md", ".json", ".yml", ".yaml", ".toml")
        if any(p in file_path.replace("\\", "/") for p in skip_patterns):
            sys.exit(0)

    # Snapshot .o → .o.prev before the edit touches the source
    if file_path:
        _snapshot_object_file(file_path)

    code = extract_code(tool_name, tool_input)
    if not code:
        sys.exit(0)

    functions = find_new_functions(code)
    if not functions:
        sys.exit(0)  # No new function body — nothing to check

    reports = []
    for func_name, body_lines in functions:
        findings = _check_call_graph(body_lines, func_name)
        reports.append(render_report(func_name, findings))

    if reports:
        print("\n".join(reports), flush=True)

    sys.exit(0)  # Always advisory — skill layer decides whether to proceed


if __name__ == "__main__":
    main()

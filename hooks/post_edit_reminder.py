#!/usr/bin/env python3
"""
PostToolUse hook — LOCI post-edit reminder.

Fires after Edit/Write/MultiEdit. If the target file is a C/C++/Rust source,
emits an additionalContext reminder telling Claude to invoke loci-post-edit.

This is the automated backstop — even if Claude misses the system-reminder
instruction, this hook puts the reminder directly in the tool-use response.

Always exits 0 (advisory, never blocking).
"""

import json
import os
import sys

_SOURCE_EXTS = {".c", ".cc", ".cpp", ".cxx", ".h", ".hpp", ".hxx", ".rs"}


def main():
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        sys.exit(0)

    tool_input = data.get("tool_input", {})

    # Extract file path from the tool input
    file_path = tool_input.get("file_path", "")
    if not file_path:
        sys.exit(0)

    # Skip non-source files
    _, ext = os.path.splitext(file_path)
    if ext.lower() not in _SOURCE_EXTS:
        sys.exit(0)

    # Skip plan files and configs that happen to have source extensions
    skip_patterns = (".claude/plans/", ".claude/settings")
    normalized = file_path.replace("\\", "/")
    if any(p in normalized for p in skip_patterns):
        sys.exit(0)

    basename = os.path.basename(file_path)
    output = {
        "hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": (
                f"[loci] {basename} was modified. "
                "You MUST invoke the loci:loci-post-edit skill NOW — "
                "do not proceed to the next edit or respond to the user first."
            ),
        }
    }
    json.dump(output, sys.stdout)
    sys.exit(0)


if __name__ == "__main__":
    main()

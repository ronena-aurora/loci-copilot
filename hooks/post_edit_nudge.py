#!/usr/bin/env python3
"""
PostToolUse hook — nudges Claude to invoke loci-post-edit after
C/C++/Rust source file edits.
"""
import json
import sys
import os

_SOURCE_EXTS = {".c", ".cc", ".cpp", ".cxx", ".h", ".hpp", ".hxx", ".rs"}


def main():
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        sys.exit(0)

    tool_input = data.get("tool_input", {})
    file_path = tool_input.get("file_path") or tool_input.get("path")
    if not file_path:
        sys.exit(0)

    _, ext = os.path.splitext(file_path)
    if ext.lower() in _SOURCE_EXTS:
        print(
            "[loci] C/C++/Rust source modified — invoke loci-post-edit skill "
            "to analyze execution impact of this change",
            flush=True,
        )


if __name__ == "__main__":
    main()

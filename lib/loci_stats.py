#!/usr/bin/env python3
"""LOCI cumulative per-branch stats tracker."""

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path

PLUGIN_DIR = Path(__file__).resolve().parent.parent
STATE_DIR = PLUGIN_DIR / "state"


def _stats_path() -> Path | None:
    """Resolve stats file from project-context.json."""
    ctx_file = STATE_DIR / "project-context.json"
    if not ctx_file.exists():
        return None
    with open(ctx_file) as f:
        ctx = json.load(f)
    cwd_hash = ctx.get("cwd_hash", "default")
    slug = ctx.get("branch_slug", "unknown")
    return STATE_DIR / f"loci-stats-{cwd_hash}-{slug}.json"


def _load(path: Path) -> dict:
    if path and path.exists():
        with open(path) as f:
            return json.load(f)
    return {
        "functions": 0,
        "mcp_calls": 0,
        "skills_invoked": 0,
        "co_reasoning": 0,
        "branch": "unknown",
        "first_recorded": datetime.now(timezone.utc).isoformat(),
        "last_recorded": None,
    }


def _global_stats_path() -> Path:
    """Global stats file — all projects, all branches, since inception."""
    return STATE_DIR / "loci-stats-global.json"


def _load_global() -> dict:
    path = _global_stats_path()
    if path.exists():
        with open(path) as f:
            return json.load(f)
    return {
        "functions": 0,
        "mcp_calls": 0,
        "skills_invoked": 0,
        "co_reasoning": 0,
        "projects_seen": [],
        "first_recorded": datetime.now(timezone.utc).isoformat(),
        "last_recorded": None,
    }


def _update_global(args):
    """Silently accumulate into global stats — never shown to users."""
    data = _load_global()
    data["functions"] += args.functions
    data["mcp_calls"] += args.mcp_calls
    data["skills_invoked"] += 1
    data["co_reasoning"] += args.co_reasoning
    data["last_recorded"] = datetime.now(timezone.utc).isoformat()
    ctx_file = STATE_DIR / "project-context.json"
    if ctx_file.exists():
        with open(ctx_file) as f:
            ctx = json.load(f)
        project = ctx.get("project_root", "unknown")
        if project not in data["projects_seen"]:
            data["projects_seen"].append(project)
    with open(_global_stats_path(), "w") as f:
        json.dump(data, f, indent=2)


def cmd_record(args):
    path = _stats_path()
    if not path:
        return
    data = _load(path)
    data["functions"] += args.functions
    data["mcp_calls"] += args.mcp_calls
    data["skills_invoked"] += 1
    data["co_reasoning"] += args.co_reasoning
    data["last_recorded"] = datetime.now(timezone.utc).isoformat()
    ctx_file = STATE_DIR / "project-context.json"
    if ctx_file.exists():
        with open(ctx_file) as f:
            ctx = json.load(f)
        data["branch"] = ctx.get("git_branch", "unknown")
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
    _update_global(args)


def cmd_summary(args):
    path = _stats_path()
    if not path:
        return
    data = _load(path)
    if data["skills_invoked"] == 0:
        return
    branch = data.get("branch", "unknown")
    parts = []
    if data["functions"] > 0:
        parts.append(f"{data['functions']} functions")
    if data["mcp_calls"] > 0:
        parts.append(f"{data['mcp_calls']} MCP calls")
    parts.append(f"{data['skills_invoked']} skills")
    suffix = f" on {branch}" if branch != "unknown" else ""
    print(f"    ↳ *{' · '.join(parts)}{suffix}*")


def main():
    parser = argparse.ArgumentParser(description="LOCI cumulative stats tracker")
    sub = parser.add_subparsers(dest="cmd")

    rec = sub.add_parser("record")
    rec.add_argument("--skill", required=True)
    rec.add_argument("--functions", type=int, default=0)
    rec.add_argument("--mcp-calls", type=int, default=0)
    rec.add_argument("--co-reasoning", type=int, default=0)

    sub.add_parser("summary")

    args = parser.parse_args()
    if args.cmd == "record":
        cmd_record(args)
    elif args.cmd == "summary":
        cmd_summary(args)


if __name__ == "__main__":
    main()

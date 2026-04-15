#!/usr/bin/env python3
"""LOCI cumulative per-branch stats tracker."""

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

# Ensure Unicode output works on Windows consoles (cp1252 can't encode ↳ etc.)
if sys.stdout.encoding and sys.stdout.encoding.lower().replace("-", "") != "utf8":
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

PLUGIN_DIR = Path(__file__).resolve().parent.parent
STATE_DIR = PLUGIN_DIR / "state"


def _stats_path() -> Path | None:
    """Resolve stats file from project-context.json."""
    ctx_file = STATE_DIR / "project-context.json"
    if not ctx_file.exists():
        return None
    with open(ctx_file, encoding="utf-8") as f:
        ctx = json.load(f)
    cwd_hash = ctx.get("cwd_hash", "default")
    slug = ctx.get("branch_slug", "unknown")
    return STATE_DIR / f"loci-stats-{cwd_hash}-{slug}.json"


def _load(path: Path) -> dict:
    if path and path.exists():
        with open(path, encoding="utf-8") as f:
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
        with open(path, encoding="utf-8") as f:
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
        with open(ctx_file, encoding="utf-8") as f:
            ctx = json.load(f)
        project = ctx.get("project_root", "unknown")
        if project not in data["projects_seen"]:
            data["projects_seen"].append(project)
    with open(_global_stats_path(), "w", encoding="utf-8") as f:
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
        with open(ctx_file, encoding="utf-8") as f:
            ctx = json.load(f)
        data["branch"] = ctx.get("git_branch", "unknown")
    with open(path, "w", encoding="utf-8") as f:
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


def cmd_global_summary(args):
    data = _load_global()
    if data["skills_invoked"] == 0:
        return
    parts = []
    if data["functions"] > 0:
        parts.append(f"{data['functions']} functions")
    if data["mcp_calls"] > 0:
        parts.append(f"{data['mcp_calls']} MCP calls")
    parts.append(f"{data['skills_invoked']} skills")
    n_projects = len(data.get("projects_seen", []))
    if n_projects > 0:
        parts.append(f"{n_projects} project{'s' if n_projects != 1 else ''}")
    first = data.get("first_recorded", "")
    since = first[:10] if first else ""
    suffix = f" since {since}" if since else ""
    print(f"    ↳ *{' · '.join(parts)}{suffix}*")


# ---------------------------------------------------------------------------
# Measurement history (JSONL)
# ---------------------------------------------------------------------------

MAX_MEASUREMENTS = 500
ROTATE_KEEP = 250


def _measurements_path() -> Path | None:
    """Resolve JSONL measurement file for current project+branch."""
    ctx_file = STATE_DIR / "project-context.json"
    if not ctx_file.exists():
        return None
    with open(ctx_file, encoding="utf-8") as f:
        ctx = json.load(f)
    cwd_hash = ctx.get("cwd_hash", "default")
    slug = ctx.get("branch_slug", "unknown")
    return STATE_DIR / f"loci-measurements-{cwd_hash}-{slug}.jsonl"


def _rotate_if_needed(path: Path) -> None:
    """Keep the file under MAX_MEASUREMENTS lines by dropping the oldest."""
    if not path.exists():
        return
    lines = path.read_text(encoding="utf-8").splitlines()
    if len(lines) <= MAX_MEASUREMENTS:
        return
    path.write_text(
        "\n".join(lines[-ROTATE_KEEP:]) + "\n", encoding="utf-8"
    )


def _read_measurements(path: Path) -> list[dict]:
    """Read all JSONL records from the measurements file."""
    if not path or not path.exists():
        return []
    records = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line:
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return records


def _build_record(fn: str, skill: str, commit: str | None,
                   source: str | None, **values) -> dict:
    """Build a single measurement record dict."""
    record = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "fn": fn,
        "skill": skill,
    }
    for key, val in values.items():
        if val is not None:
            record[key] = val
    if commit:
        record["commit"] = commit
    if source:
        record["src"] = source
    return record


def cmd_record_measurement(args):
    path = _measurements_path()
    if not path:
        return

    if args.stdin:
        # Batch mode: read JSONL from stdin, merge with CLI shared fields
        ts = datetime.now(timezone.utc).isoformat()
        records = []
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            record = {"ts": ts, "fn": row.get("fn", "unknown"), "skill": args.skill}
            for key in ("worst_ns", "happy_ns", "energy_uws", "stack_b", "rom_b", "src"):
                if key in row:
                    record[key] = row[key]
            if args.commit:
                record["commit"] = args.commit
            records.append(record)
        if records:
            with open(path, "a", encoding="utf-8") as f:
                for r in records:
                    f.write(json.dumps(r, separators=(",", ":")) + "\n")
            _rotate_if_needed(path)
        return

    # Single-record mode (backwards compatible)
    record = _build_record(
        fn=args.function, skill=args.skill,
        commit=args.commit, source=args.source,
        worst_ns=args.worst_ns, happy_ns=args.happy_ns,
        energy_uws=args.energy_uws, stack_b=args.stack_bytes,
        rom_b=args.rom_bytes,
    )
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps(record, separators=(",", ":")) + "\n")
    _rotate_if_needed(path)


def _direction(values: list[float]) -> str:
    """Classify trend direction from a list of chronological values.

    All LOCI metrics are lower-is-better (timing, stack, ROM), so
    latest > first means regression, latest < first means improvement.
    """
    if len(values) < 2:
        return "baseline"
    first, last, peak = values[0], values[-1], max(values)
    if abs(last - first) / max(abs(first), 1e-9) < 0.03:
        return "stable"
    if last < first:
        return "improved"
    # last > first — regressed from baseline
    if last < peak and (peak - last) / max(abs(peak), 1e-9) > 0.05:
        return "recovering"
    return "regressed"


def _format_value(val: float, unit: str) -> str:
    """Format a measurement value with its unit."""
    if unit == "ns":
        return f"{val:.0f} ns" if val >= 1 else f"{val:.2f} ns"
    if unit == "uWs":
        return f"{val:.2f} uWs"
    if unit == "B":
        return f"{int(val)} B"
    return f"{val}"


_METRIC_DEFS = [
    ("worst_ns", "ns", "worst-path"),
    ("stack_b", "B", "stack"),
    ("rom_b", "B", "rom"),
]


def _detect_metrics(records: list[dict]) -> list[tuple[str, str, str]]:
    """Return all (key, unit, label) tuples present in a group of records."""
    found = []
    for key, unit, label in _METRIC_DEFS:
        if any(key in r for r in records):
            found.append((key, unit, label))
    return found


def cmd_trend(args):
    path = _measurements_path()
    records = _read_measurements(path)
    if not records:
        return

    if args.function:
        # Single function — chronological list
        fn_records = [r for r in records if r.get("fn") == args.function]
        if not fn_records:
            return
        for r in fn_records:
            ts = r.get("ts", "")[:10]
            commit = r.get("commit", "")
            parts = []
            if "worst_ns" in r:
                parts.append(f"worst={_format_value(r['worst_ns'], 'ns')}")
            if "energy_uws" in r:
                parts.append(f"energy={_format_value(r['energy_uws'], 'uWs')}")
            if "stack_b" in r:
                parts.append(f"stack={_format_value(r['stack_b'], 'B')}")
            if "rom_b" in r:
                parts.append(f"rom={_format_value(r['rom_b'], 'B')}")
            commit_str = f"  ({commit})" if commit else ""
            print(f"  {ts}  {', '.join(parts)}{commit_str}")
        return

    # All functions — summary table (one row per function per metric type)
    groups: dict[str, list[dict]] = {}
    for r in records:
        fn = r.get("fn", "unknown")
        groups.setdefault(fn, []).append(r)

    rows = []
    for fn, fn_records in groups.items():
        for metric_key, unit, metric_label in _detect_metrics(fn_records):
            values = [r[metric_key] for r in fn_records if metric_key in r]
            if not values:
                continue
            edits = len(values)
            first_val = values[0]
            latest_val = values[-1]
            direction = _direction(values)
            if direction == "baseline":
                net = "--"
            else:
                peak = max(values)
                if peak > latest_val and peak != first_val:
                    pct = ((latest_val - peak) / abs(peak)) * 100
                    net = f"{pct:+.0f}% from peak"
                else:
                    pct = ((latest_val - first_val) / max(abs(first_val), 1e-9)) * 100
                    net = f"{pct:+.0f}%"
            # Only add suffix when the metric isn't the default (timing)
            label = fn if metric_label == "worst-path" else f"{fn} ({metric_label})"
            rows.append((label, edits, _format_value(first_val, unit),
                          _format_value(latest_val, unit), direction, net))

    if not rows:
        return

    # Compute column widths
    headers = ("Function", "Edits", "First", "Latest", "Direction", "Net")
    widths = [len(h) for h in headers]
    for row in rows:
        for i, cell in enumerate(row):
            widths[i] = max(widths[i], len(str(cell)))

    fmt = "  ".join(f"{{:<{w}}}" for w in widths)
    print(fmt.format(*headers))
    for row in rows:
        print(fmt.format(*[str(c) for c in row]))

    total = sum(r[1] for r in rows)
    print(f"\nBranch summary: {len(rows)} functions tracked, {total} measurements")


def _trend_line_for(fn: str, records: list[dict]) -> str | None:
    """Return a single trend line string for a function, or None."""
    fn_records = [r for r in records if r.get("fn") == fn]
    if len(fn_records) < 2:
        return None
    metrics = _detect_metrics(fn_records)
    if not metrics:
        return None
    metric_key, unit, metric_label = metrics[0]
    values = [r[metric_key] for r in fn_records if metric_key in r]
    if len(values) < 2:
        return None

    arrow_parts = [_format_value(v, unit).split()[0] for v in values[-5:]]
    trail = " -> ".join(arrow_parts) + f" {unit}"

    peak = max(values)
    latest = values[-1]
    if peak > latest and peak != values[0]:
        pct = ((latest - peak) / abs(peak)) * 100
        note = f"{pct:+.0f}% from peak"
    else:
        pct = ((latest - values[0]) / max(abs(values[0]), 1e-9)) * 100
        note = f"{pct:+.0f}%"

    return f"{fn} {metric_label}: {trail} ({len(values)} edits, {note})"


def cmd_trend_line(args):
    path = _measurements_path()
    records = _read_measurements(path)
    if not records:
        return
    # Accept comma-separated functions or a single function
    functions = [f.strip() for f in args.function.split(",") if f.strip()]
    for fn in functions:
        line = _trend_line_for(fn, records)
        if line:
            print(line)


def cmd_export_impact(args):
    """Export session-scoped impact metrics as JSON to stdout.

    Scoped to --functions if provided (comma-separated). Uses full measurement
    history for direction classification but only counts specified functions.
    """
    path = _measurements_path()
    records = _read_measurements(path)
    if not records:
        print(json.dumps({"functionsAnalyzed": 0}))
        return

    # Group by function name
    by_fn = {}
    for r in records:
        fn = r.get("fn", "unknown")
        by_fn.setdefault(fn, []).append(r)

    # Scope to requested functions if provided
    if args.functions:
        scope = {f.strip() for f in args.functions.split(",") if f.strip()}
    else:
        scope = set(by_fn.keys())

    counts = {"improved": 0, "regressed": 0, "stable": 0, "recovering": 0, "baseline": 0}
    total_energy_saved = 0.0
    total_stack_saved = 0
    improvement_pcts = []

    for fn in scope:
        fn_records = by_fn.get(fn, [])
        if not fn_records:
            counts["baseline"] += 1
            continue

        # Classify direction using worst_ns (primary metric)
        worst_vals = [r["worst_ns"] for r in fn_records if "worst_ns" in r]
        direction = _direction(worst_vals) if worst_vals else "baseline"
        counts[direction] = counts.get(direction, 0) + 1

        # Improvement % for improved functions
        if direction == "improved" and len(worst_vals) >= 2:
            pct = (worst_vals[0] - worst_vals[-1]) / max(abs(worst_vals[0]), 1e-9) * 100
            improvement_pcts.append(pct)

        # Energy delta (improvements only)
        energy_vals = [r["energy_uws"] for r in fn_records if "energy_uws" in r]
        if len(energy_vals) >= 2 and energy_vals[-1] < energy_vals[0]:
            total_energy_saved += energy_vals[0] - energy_vals[-1]

        # Stack delta (improvements only)
        stack_vals = [r["stack_b"] for r in fn_records if "stack_b" in r]
        if len(stack_vals) >= 2 and stack_vals[-1] < stack_vals[0]:
            total_stack_saved += int(stack_vals[0] - stack_vals[-1])

    # Build skills_used from --skill arg
    skills_used = {}
    if args.skill:
        skills_used[args.skill] = 1

    co_reasoning = getattr(args, "co_reasoning", 0) or 0

    result = {
        "functionsAnalyzed": len(scope),
        "functionsImproved": counts["improved"],
        "functionsRegressed": counts["regressed"],
        "functionsStable": counts["stable"],
        "functionsRecovering": counts["recovering"],
        "functionsBaseline": counts["baseline"],
        "improvementPctSum": round(sum(improvement_pcts), 2) if improvement_pcts else 0,
        "improvedCount": len(improvement_pcts),
        "totalEnergySavedUws": round(total_energy_saved, 2),
        "totalStackSavedB": total_stack_saved,
        "regressionsCaught": counts["recovering"] + counts["regressed"],
        "coReasoningSessions": co_reasoning,
        "skillsUsed": skills_used,
    }
    print(json.dumps(result, separators=(",", ":")))


def main():
    parser = argparse.ArgumentParser(description="LOCI cumulative stats tracker")
    sub = parser.add_subparsers(dest="cmd")

    rec = sub.add_parser("record")
    rec.add_argument("--skill", required=True)
    rec.add_argument("--functions", type=int, default=0)
    rec.add_argument("--mcp-calls", type=int, default=0)
    rec.add_argument("--co-reasoning", type=int, default=0)

    sub.add_parser("summary")
    sub.add_parser("global-summary")

    rm = sub.add_parser("record-measurement")
    rm.add_argument("--function", default=None)
    rm.add_argument("--skill", required=True, dest="skill")
    rm.add_argument("--stdin", action="store_true",
                    help="Read JSONL records from stdin (batch mode)")
    rm.add_argument("--worst-ns", type=float, default=None)
    rm.add_argument("--happy-ns", type=float, default=None)
    rm.add_argument("--energy-uws", type=float, default=None)
    rm.add_argument("--stack-bytes", type=int, default=None)
    rm.add_argument("--rom-bytes", type=int, default=None)
    rm.add_argument("--commit", default=None)
    rm.add_argument("--source", default=None)

    tr = sub.add_parser("trend")
    tr.add_argument("--function", default=None)

    tl = sub.add_parser("trend-line")
    tl.add_argument("--function", required=True)

    ei = sub.add_parser("export-impact")
    ei.add_argument("--functions", default=None,
                    help="Comma-separated function names to scope")
    ei.add_argument("--skill", default=None,
                    help="Current skill name for skillsUsed")
    ei.add_argument("--co-reasoning", type=int, default=0,
                    help="Co-reasoning sessions from this skill run")

    args = parser.parse_args()
    if args.cmd == "record":
        cmd_record(args)
    elif args.cmd == "summary":
        cmd_summary(args)
    elif args.cmd == "global-summary":
        cmd_global_summary(args)
    elif args.cmd == "record-measurement":
        cmd_record_measurement(args)
    elif args.cmd == "trend":
        cmd_trend(args)
    elif args.cmd == "trend-line":
        cmd_trend_line(args)
    elif args.cmd == "export-impact":
        cmd_export_impact(args)


if __name__ == "__main__":
    main()

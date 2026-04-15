---
name: trends
description: >
  Per-function measurement history on the current branch: timing, energy,
  stack, and memory trends over time from LOCI analysis.
when_to_use: >
  When user says "show trends", "optimization progress", "what changed on
  this branch", "how are my functions doing", "/trends". Also when user asks
  about performance trajectory or whether an optimization sprint is working.
---

# LOCI Trends

Read these values from the LOCI session context (system-reminder block at
session start) and substitute them wherever the placeholders appear below:
- `venv python: <path>` → use as `<venv-python>`
- `plugin dir: <path>` → use as `<plugin-dir>`

## Step 0: Check session context

Read the persisted detection results from `state/project-context.json` in the
plugin directory. Extract `git_branch` for the report header.

If the file does not exist, stop and tell the user:

> LOCI session context not found. Please restart Claude Code so the plugin
> setup runs and detects the project environment.

## Step 1: Retrieve trend summary

Run via Bash:
```
<venv-python> <plugin-dir>/lib/loci_stats.py trend
```

If the output is empty, respond with:

> No measurements on this branch.

Nothing more. Do not suggest running other skills or explain how to generate
measurements.

## Step 2: Render the report

If step 1 produced output, render it with a heading that includes the branch
name from step 0:

```
## LOCI Trends: <branch_name>

<trend output from step 1>
```

The table shows only columns that have data — timing from post-edit
auto-runs, stack from /stack-depth invocations, memory from /memory-report
invocations. No empty columns, no missing-data notices.

## Step 3: Single-function drill-down (optional)

If the user asks about a specific function, run:
```
<venv-python> <plugin-dir>/lib/loci_stats.py trend --function <func_name>
```

Render the chronological output under a heading:
```
### <func_name>

<chronological output from above>
```

## LOCI voice remark

Before the footer, add one short LOCI voice remark (max 15 words) grounded
in a specific number from the trend data. Examples:
- "3 functions improved since branch start. Solid progress."
- "process_data recovering — down 25% from peak regression."
- "All functions stable. Clean branch."
Skip if there is no data or only baselines (single measurements).

## LOCI footer

After rendering the report, append this footer:

```
─── LOCI · trends ──────────────────────
────────────────────────────────────────
```

Do NOT record stats for this skill — trends is a read-only view.

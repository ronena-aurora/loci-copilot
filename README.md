# loci-plugin

A Claude Code plugin with safety analysis skills and file instrumentation for C/C++ development.

## Install

```
/plugin marketplace add auroralabs-loci/loci-plugin-2
/plugin install loci-plugin@loci-plugin
```

## Skills

**loci-preflight** — Before writing any function, reasons through call graph ordering, arithmetic ranges, and freed-resource access to catch bugs while the plan is still cheap to change.

**loci-post-review** — After a code agent writes or edits code, runs the same three checks against the actual diff and returns APPROVE / FLAG / REVERT.

**exec-trace** — Compiles to a LOCI target architecture and reports execution time and energy consumption from real hardware traces.

**char-counter** — After every Edit/Write/MultiEdit, appends a one-line character count summary to the response.

## Hooks

| Hook | Trigger | Action |
|------|---------|--------|
| `SessionStart` | startup | runs `setup/setup.sh` |
| `PreToolUse` | Edit, Write, MultiEdit | preflight safety check |
| `PostToolUse` | Edit, Write, MultiEdit | character count |

## LOCI MCP

Connects to `https://dev.local.mcp.loci-dev.net/mcp` for live call graph and symbol data when available.

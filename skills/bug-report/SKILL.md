---
name: bug-report
description: >
  Forensic diagnostic report for LOCI — collects environment state, runs health
  checks, and writes a timestamped report when analysis fails or doesn't trigger.
  Invoke when: "bug report", "LOCI isn't working", "exec-trace didn't run",
  "skill didn't trigger", "MCP not connecting", "results are wrong",
  "results missing", "generate diagnostic", "something is broken",
  "debug LOCI", or any LOCI failure the user wants investigated.
user-invocable: true
argument-hint: "[description of what failed]"
---

# LOCI Bug Report

Generate a forensic diagnostic report when LOCI analysis fails, a skill does
not invoke, or results are missing or invalid. The report is written to a
timestamped `.md` file that can be shared or loaded into a future Claude Code
session to diagnose and fix the issue.

This skill must work even when LOCI is completely broken. Do NOT use MCP tools.
Use only: Read, Bash, Glob, Grep.

Read these values from the LOCI session context (system-reminder block at
session start) and substitute them wherever the placeholders appear below:
- `asm-analyze command: <path>` → use as `<asm-analyze-cmd>`
- `venv python: <path>` → use as `<venv-python>`
- `plugin dir: <path>` → use as `<plugin-dir>`

If `plugin dir:` is not in the session context, fall back to the
`CLAUDE_PLUGIN_ROOT` environment variable. If neither is available, stop and
tell the user: "Cannot locate LOCI plugin directory. Ensure the plugin is
installed and restart Claude Code."

## Step 0: Capture user description

The skill accepts an optional argument string describing the problem.
Store it as `<user-description>`.

If no argument was provided, ask the user in one sentence:
"What did you expect LOCI to do, and what happened instead?"

## Step 1: Collect environment snapshot

Run these in parallel where possible via Bash and Read:

1. **Claude Code version** — `claude --version 2>/dev/null || echo "unknown"`
2. **Claude model** — read from the current session context (you know the model
   name from your system prompt, e.g. "claude-opus-4-6", "claude-sonnet-4-6").
   Record the exact model ID.
3. **Plugin version** — Read `<plugin-dir>/../../../.claude-plugin/marketplace.json`
   (or the repo-level `.claude-plugin/marketplace.json`), extract
   `plugins[0].version`. If not found, try `<plugin-dir>/../../marketplace.json`.
   Fall back to "unknown".
4. **OS info** — `uname -a`
5. **OS short name** — `uname -s | tr '[:upper:]' '[:lower:]'` (for filename)
6. **Project context** — Read `<plugin-dir>/state/project-context.json` (full JSON).
   If missing, record "MISSING".
7. **LOCI paths** — Read `<plugin-dir>/state/loci-paths.json`. If missing,
   record "MISSING".
8. **Setup marker** — `cat <plugin-dir>/.setup-complete 2>/dev/null || echo "MISSING"`
9. **Git info** — `git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown"`
   and `git log --oneline -3 2>/dev/null || echo "no git history"`
10. **Hooks config** — Read `<plugin-dir>/hooks/hooks.json`. If missing,
    record "MISSING".

## Step 2: Run 12-point diagnostics checklist

For each check, record status (PASS / FAIL) and a detail string.

| # | Check | How to test | PASS when |
|---|-------|-------------|-----------|
| 1 | MCP tools visible | Check if `mcp__plugin_loci_loci__get_assembly_block_exec_behavior` appears as an available tool in the current session | Tool is listed |
| 2 | Session context exists | `<plugin-dir>/state/project-context.json` exists and contains `project_root` | File exists with key |
| 3 | Compiler detected | `compiler` field in project-context.json is not `unknown` or empty | Has a value |
| 4 | Architecture detected | `architecture` field in project-context.json is not `unknown` or empty | Has a value |
| 5 | LOCI target supported | `loci_target` in project-context.json is one of: `aarch64`, `armv7e-m`, `armv6-m`, `tc3xx` | Value in set |
| 6 | Python venv working | `<venv-python> --version` exits 0 | Exit code 0 |
| 7 | asm-analyze installed | `<venv-python> -c "from loci.service.asmslicer import asmslicer"` exits 0 | Exit code 0 |
| 8 | Setup complete | `.setup-complete` file exists in plugin dir | File exists |
| 9 | Build artifacts exist | Glob for `.loci-build/**/*.o` or any `.elf`/`.o`/`.axf` in project root | At least one found |
| 10 | c++filt available | Read `cxxfilt_dir` from `loci-paths.json`, run `<cxxfilt_dir>/c++filt --version` | Exit code 0 |
| 11 | session-init executable | `test -x <plugin-dir>/hooks/session-init.sh` | Exit code 0 |
| 12 | hooks.json valid | `<plugin-dir>/hooks/hooks.json` parses as JSON | Valid JSON |

If `<venv-python>` is unavailable, checks 6, 7 automatically FAIL.
If `loci-paths.json` is missing, check 10 automatically FAILs.

## Step 3: Collect stats

Run via Bash (skip if venv is broken):
```
<venv-python> <plugin-dir>/lib/loci_stats.py summary
<venv-python> <plugin-dir>/lib/loci_stats.py global-summary
```

Record output or "stats unavailable — venv not working".

## Step 4: Reasoning — common failure forensics

This is the most important section. Analyze the session context and
diagnostics to determine what went wrong. Write this as free-form reasoning
(not templated) so it captures the actual session state.

### A. Skill Not Invoked

If the user's issue is that a LOCI skill should have triggered but didn't,
investigate:

1. **Prompt match** — compare the user's original prompt against the
   `when_to_use` triggers for each relevant skill. List the trigger keywords
   from the SKILL.md and note which matched or didn't.

2. **Auto-run conditions** — for auto-triggered skills:
   - `loci-post-edit`: Was the edited file a C/C++/Rust source
     (.c, .cc, .cpp, .cxx, .h, .hpp, .hxx, .rs)? Was an Edit/Write/MultiEdit
     tool used?
   - `loci-preflight`: Was Claude in `/plan` mode when the user described
     new logic?

3. **Skill visibility** — is the skill listed in the `Available:` line of the
   session-reminder? If not, session-init may not have registered it.

4. **Deferred tools** — check if `loci:loci-post-edit`, `loci:loci-preflight`,
   etc. appear in the system-reminder deferred tools / available skills list.
   If absent, the plugin may not be loaded.

5. **Competing behavior** — did Claude answer directly instead of invoking the
   skill? Did another skill or tool pre-empt? Note what Claude did instead.

### B. Results Not Evaluated or Not Valid

If a skill ran but produced no results, wrong results, or results that weren't
used, investigate:

1. **Compilation** — did the compilation step succeed? Look for compiler errors,
   missing headers, wrong flags. Check if the compiler from project-context.json
   is actually installed: `which <compiler>`.

2. **asm-analyze output** — did `extract-assembly` or `extract-cfg` produce
   valid JSON? Common failures: function name not found in binary, architecture
   mismatch between ELF and LOCI target, empty output.

3. **MCP response** — did the MCP call return timing/energy data? Common
   failures: MCP timeout, authentication expired mid-session, server error,
   empty response. Check if MCP was authenticated at session start (check 1).

4. **Result parsing** — were `timing_csv_chunks`, `timing_architecture`, or
   `execution_time_ns` fields present in the output? If asm-analyze returned
   data but Claude didn't use it, note the gap.

5. **Delta comparison** — for post-edit: did `.o.prev` exist before the
   recompile? Did `diff-elfs` return 0 changed functions (meaning the binary
   didn't actually change)?

6. **Output suppression** — did Claude generate analysis but fail to present
   it? (Context window pressure, interrupted response, tool call error.)

### C. Root cause

Based on the diagnostics and reasoning above, state the root cause. Use the
dependency chain to find the most upstream failure:

```
hooks → setup → venv → asm-analyze → project-context → MCP → compilation → analysis
```

If all 12 checks pass, the issue is likely:
- Skill trigger wording mismatch (Claude didn't recognize the intent)
- Transient MCP timeout
- A bug in the skill logic itself

## Step 5: Write report file

Determine the output filename:
```
report-<YYYY-MM-DD>-<os-short>.md
```

Write the file to the current working directory using this structure:

```markdown
# LOCI Diagnostic Report

Generated: <YYYY-MM-DD HH:MM:SS UTC>

## Versions

| Component | Version |
|-----------|---------|
| Claude Code | <claude --version output> |
| Claude model | <model ID, e.g. claude-opus-4-6> |
| LOCI plugin | <plugin version> |
| OS | <uname -a output> |

## User Description

<user-description>

## Environment

| Field | Value |
|-------|-------|
| Project root | <project_root or cwd> |
| Git branch | <branch> |
| Compiler | <compiler or "unknown"> |
| Build system | <build_system or "unknown"> |
| Architecture | <architecture or "unknown"> |
| LOCI target | <loci_target or "unknown"> |
| MCP status | <connected / not authorized> |
| asm-analyze | <command path or "unavailable"> |
| venv python | <path or "unavailable"> |

## Diagnostics Checklist

| # | Check | Status | Detail |
|---|-------|--------|--------|
| 1 | MCP tools visible | <PASS/FAIL> | <detail> |
| 2 | Session context exists | <PASS/FAIL> | <detail> |
| 3 | Compiler detected | <PASS/FAIL> | <detail> |
| 4 | Architecture detected | <PASS/FAIL> | <detail> |
| 5 | LOCI target supported | <PASS/FAIL> | <detail> |
| 6 | Python venv working | <PASS/FAIL> | <detail> |
| 7 | asm-analyze installed | <PASS/FAIL> | <detail> |
| 8 | Setup complete | <PASS/FAIL> | <detail> |
| 9 | Build artifacts exist | <PASS/FAIL> | <detail> |
| 10 | c++filt available | <PASS/FAIL> | <detail> |
| 11 | session-init executable | <PASS/FAIL> | <detail> |
| 12 | hooks.json valid | <PASS/FAIL> | <detail> |

**Result: <N>/12 checks passed.**

## Reasoning

### What the user was trying to do
<describe the intent and expected behavior>

### What should have happened
<which skill should have triggered, with trigger conditions from when_to_use>

### What actually happened
<what Claude did instead — answered directly, wrong skill, error, silence>

### Why it failed
<root cause reasoning chain, referencing specific checklist failures>

### Skill trigger analysis
<for each relevant skill, did the trigger conditions match?>

## Diagnosis

**Root cause:** <one-sentence root cause>

**Contributing factors:** <any additional FAIL checks>

**Suggested fix:**
<numbered actionable steps to resolve>

## Stats

### Branch stats
<loci_stats.py summary output, or "no stats recorded">

### Global stats
<loci_stats.py global-summary output, or "no stats recorded">

### Redaction

Before embedding any file contents in the Raw Data section below, sanitize
them:

1. **Secrets** — replace values matching common secret patterns (API keys,
   tokens, passwords, `Bearer ...`, `Authorization: ...`, private key blocks)
   with `[REDACTED]`.
2. **Home paths** — replace the user's home directory prefix
   (`/Users/<name>/`, `/home/<name>/`, `C:\Users\<name>\`) with `~/`.

Apply these substitutions in-memory before writing the report. Do NOT write
unsanitized contents and edit afterward.

## Raw Data

<details>
<summary>project-context.json</summary>

```json
<sanitized contents or "MISSING">
```
</details>

<details>
<summary>loci-paths.json</summary>

```json
<sanitized contents or "MISSING">
```
</details>

<details>
<summary>hooks.json</summary>

```json
<sanitized contents or "MISSING">
```
</details>

<details>
<summary>.setup-complete</summary>

<sanitized contents or "MISSING">
</details>

<details>
<summary>Recent git log</summary>

<git log --oneline -3 output>
</details>
```

## Step 6: Present summary to user

After writing the report file, display a concise summary:

```
## LOCI Diagnostic Summary

<N>/12 checks passed.

**Root cause:** <one-sentence diagnosis>

**Suggested fix:**
<numbered steps>

Share this file when reporting issues, or open it in a new Claude Code
session for further investigation.

─── LOCI · bug-report ─────────────────
  Report: <absolute-path-to-report-file>
────────────────────────────────────────
```

The report file path MUST appear in the footer as the last visible output.
Use the absolute path so the user can copy-paste it directly.

Do NOT record stats for this skill (diagnostic/informational only).
Do NOT emit a LOCI voice remark (inappropriate for failure context).

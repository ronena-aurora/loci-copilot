---
description: >
  Quick-reference guide to LOCI — shows available skills, environment status,
  and troubleshooting for build environment and MCP connection issues.
when_to_use: >
  When user asks for help with LOCI, what LOCI can do, how to use LOCI,
  available commands, or types /help. Also when user seems confused about
  LOCI setup or capabilities.
---

# LOCI Help

Show the user their environment status, available skills, and a contextual
next step. Adapt the output based on what is actually working vs missing.

## Step 0: Diagnose Environment

Read the LOCI session context from the `system-reminder` block emitted at
session start:

```
Target: <target>, Compiler: <compiler>, Build: <build>
LOCI target: <loci_target>
```

Classify the environment into one of three states:

| State | How to detect | Priority |
|-------|---------------|----------|
| **MCP not authorized** | `mcp__plugin_loci_loci__get_assembly_block_exec_behavior` is NOT visible as an available tool | Check first |
| **No build env** | Target = `unknown` OR Compiler = `unknown` in session context | Check second |
| **Ready** | Target and Compiler are both known, MCP tools are visible | Default |

A session can be in multiple degraded states simultaneously (no build env AND
no MCP). Report all that apply.

## Step 1: Show Environment Status

Based on Step 0, render the appropriate status block.

### When fully ready

```
## Environment
  Target:    <loci_target> (<mapped CPU name>)
  Compiler:  <compiler>
  Build:     <build_system>
  MCP:       connected
```

Map LOCI target to CPU name:

| LOCI target | CPU |
|---|---|
| aarch64 | A53 |
| cortexm / armv7e-m | Cortex-M4 |
| armv6-m | Cortex-M0+ |
| tricore / tc3xx | TC399 |

### When build environment is missing

```
## Environment — setup needed

LOCI didn't detect a build environment in this directory.

To get started:
1. `cd` into a C/C++/Rust project with source files
2. Ensure a cross-compiler is installed:
   - ARM Cortex-M: `arm-none-eabi-gcc`
   - ARM Cortex-A: `aarch64-linux-gnu-gcc`
   - TriCore: `tricore-elf-gcc`
3. Restart Claude Code so LOCI can auto-detect the project

Or point LOCI at an existing binary directly:
  "What's the execution cost of main() in path/to/firmware.elf?"
```

### When MCP is not authorized

```
## Environment — MCP authorization needed

LOCI's timing and energy analysis requires the MCP server to be connected.

→ Run `/mcp` in Claude Code and approve the **loci** server.
  If it doesn't appear, restart Claude Code — the plugin registers it on startup.

Skills that work without MCP: /stack-depth, /memory-report, /control-flow
Skills that need MCP:         /exec-trace, loci-preflight, loci-post-edit
```

## Step 2: Show Available Skills

Always show the full skill list regardless of environment state — users
should know what's possible even if their setup isn't complete yet.

```
## On-demand skills

  /exec-trace      Timing & energy from real silicon traces
                   "What's the execution cost of main()?"

  /stack-depth     Worst-case stack depth & budget check
                   "Is my stack safe for TaskMain with 2048 bytes?"

  /memory-report   ROM/RAM breakdown from ELF/map files
                   "How much ROM/RAM does my build use?"

  /control-flow    Annotated control-flow graphs
                   "Show me the call graph for process_data()"

## Auto-running (no command needed)

  loci-preflight   Runs in /plan — checks call graph, timing, energy, execution fit
                   Escalates to /stack-depth or /memory-report when needed
                   Verdict: GOOD / ADJUST PLAN / STOP

  loci-post-edit   Runs after edits — diffs binary, reports timing/energy % delta
                   Verdict: OK / CAUTION / FLAG (proposes fix on FLAG)
```

## Step 3: Contextual Next Step

Based on the environment state from Step 0, suggest a single next action:

- **Ready + ELF files exist in project**: "You have compiled binaries — try asking about timing for a specific function, or run `/memory-report` for a full ROM/RAM breakdown."
- **Ready + no ELF files**: "Compile your project first, then ask about timing or stack depth for a specific function."
- **No build env**: "Navigate to your C/C++/Rust project directory and restart Claude Code, or point me at a `.elf`, `.o`, or `.axf` file directly."
- **MCP not authorized**: "Run `/mcp` and approve the loci server to unlock timing and energy analysis."

If multiple issues exist, prioritize MCP authorization first (it's the quicker fix),
then build environment setup.

## Stats Footer

After rendering all help output, run via Bash:
```
<venv-python> <plugin-dir>/lib/loci_stats.py global-summary
```

If output is non-empty, append it as the last line — no heading, just the
stats line. If empty (first-time user), show nothing.

Do NOT record stats for this skill — help is informational only.


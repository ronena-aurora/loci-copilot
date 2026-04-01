---
description: >
  Worst-case stack depth analysis for embedded C/C++/Rust: call-graph traversal,
  per-function frame sizes, recursion detection, and stack budget pass/fail from
  compiled .o or linked ELF binaries.
when_to_use: >
  When user asks about stack sizing, stack overflow, task stack budgets, frame
  size impact of a change, or RAM optimization in embedded/RTOS projects. Also
  when investigating hard faults or sizing new RTOS tasks.
---

# LOCI Stack Depth Analysis

Use the asm-analyze command which is a python script from lib/asm_analyze.py in the plugin dir, also use the python version from .venv folder in the plugin dir.

The practical workflow is: use `.o` for fast incremental checks on individual files
(did my change increase the frame?), use the linked ELF for full worst-case depth.

## Step 0: Check Session Context

Read architecture and compiler from the LOCI session context (the
`system-reminder` block emitted at session start). Look for:

```
Target: <target>, Compiler: <compiler>, Build: <build>
LOCI target: <loci_target>
```

Map the LOCI target to supported architectures:

| LOCI target | CPU |
|---|---|
| aarch64 | A53 |
| armv7e-m | CortexM4 |
| armv6-m | CortexM0P |
| tc3xx | TC399 |

If the architecture is **not** in this table, emit and stop:

```
Supported: aarch64, armv7e-m, armv6-m, tc3xx
```

If no compiler was detected, inform the user and stop.

Do **not** re-run detection scripts — use the values already in the session context.

If the user provides their own binary (.elf, .out, .o, .axf), asm_analyze.py
auto-detects architecture from the ELF.

## Step 1: Identify Entry Functions and Stack Budgets

Determine which functions to analyze:

1. **User provides them** — e.g., "analyze stack depth for `TaskMain` with 2048-byte stack"
2. **Search RTOS config** — look for task creation calls:
   - FreeRTOS: `xTaskCreate(..., stackSize)`, `Task_construct(...)`
   - AUTOSAR: OS task configuration
   - `FreeRTOSConfig.h`, `ti_drivers_config.h`, linker scripts
3. **Auto-detect roots** — if no entry functions specified, the tool finds root functions
   (those not called by any other function in the binary)

Stack budget is optional. If provided, the tool reports usage as a percentage and
gives a pass/fail verdict against the threshold.

## Incremental Path — `.o` files (preferred for per-file checks)

Use this when checking if a change to a single file increased the stack frame.
Works on individual `.o` object files without needing a fully linked binary.

1. If a previous `.o` exists, save it as `.o.prev`
2. Compile only the changed source with `-c`:
   ```
   <compiler> <flags> -c <source> -o .loci-build/<arch>/<basename>.o
   ```
3. Run stack depth on the new object file:
   ```
   <asm-analyze-cmd> stack-depth --elf-path .loci-build/<arch>/<basename>.o --entry-functions <func>
   ```
4. Compare frame sizes before and after. If `.o.prev` exists, also run:
   ```
   <asm-analyze-cmd> stack-depth --elf-path .loci-build/<arch>/<basename>.o.prev --entry-functions <func>
   ```
   Report the per-function frame size delta.

This gives fast feedback on whether a change grew the stack without needing a full link.

## Full ELF Path — linked binary (for worst-case depth)

Use this for full call-graph traversal to find the worst-case stack depth across
all call chains from a task entry point.

1. Cross-compile or use the existing linked binary
2. Run full stack depth analysis:
   ```
   <asm-analyze-cmd> stack-depth --elf-path <binary> --entry-functions <funcs> [--stack-budget <bytes>] [--threshold <percent>]
   ```
   Optional flags:
   - `--stack-budget <bytes>` — configured stack size; enables usage % and verdict
   - `--threshold <percent>` — max allowed usage percentage (default 50)
   - `--max-recursion-depth <N>` — bound for recursive call estimation (default 1)
   - `--unknown-callee-size <bytes>` — assumed frame size for external/library functions (default 64)

The JSON output contains per-entry-function results with:
- `worst_case_depth` — total bytes along the deepest call path
- `worst_case_path` — list of function names along that path
- `average_depth` — mean depth across all leaf-terminating paths
- `per_function_frames` — frame size in bytes for each function
- `budget`, `threshold_pct`, `usage_pct`, `verdict` — only when `--stack-budget` is provided
- `warnings` — recursion, indirect calls, unknown callees
- `has_recursion`, `has_indirect_calls`, `has_unknown_callees` — boolean flags

## Step 2: Report Results

**Important:** Always include `Worst-case path` for every reported function — do not omit it even when reporting many functions. If the output would be long, limit the number of functions reported (e.g., top 10 by depth) but always show the complete report for each function you do include.

### Per-function report

For each entry function, report:

```
## Stack Depth: <FunctionName>

Worst-case depth:   <N> bytes
Worst-case path:    func_a → func_b → func_c → func_d
Average depth:      <M> bytes
Frame size:         <F> bytes (this function only)

Per-function frames along worst path:
  func_a:   32 bytes
  func_b:   64 bytes
  func_c:  128 bytes
  func_d:   88 bytes
```

### With stack budget (when --stack-budget provided)

```
Stack budget:       2048 bytes
Threshold (50%):    1024 bytes
Worst-case usage:   312 bytes (15.2%)
Verdict:            PASS
```

### Warnings

Flag any issues that affect accuracy:
- **Recursion detected**: `func_x calls itself — depth bounded to N iterations`
- **Indirect calls**: `func_y has indirect call (blr x8) — callee unknown`
- **Unknown callees**: `func_z not found in binary — assumed 64 bytes`

These warnings mean the reported depth is an estimate. Indirect calls and unknown
callees may undercount the real depth.

### Incremental comparison (when .o.prev available)

```
## Stack Frame Delta: <FunctionName>

Before:  48 bytes
After:   96 bytes
Delta:  +48 bytes (+100%)
```

## LOCI voice remark

Before the footer, add one short LOCI voice remark (max 15 words) that
acknowledges the user's work grounded in a specific number from the
analysis. Attribute improvements to the user ("clean work", "smart move",
"tight code"). For concerns, be honest and constructive with specifics.
Skip if the analysis produced no results or the user needs raw data only.

## LOCI footer

After emitting all per-function stack depth reports, append this footer once as the
very last thing printed — **only if N > 0**. If no functions were processed, do NOT emit the footer.

**Record cumulative stats** (run via Bash before rendering the footer):
```
<venv-python> <plugin-dir>/lib/loci_stats.py record --skill stack-depth --functions <N> --mcp-calls 0 --co-reasoning 0
```

**Read cumulative summary** (run via Bash; capture output):
```
<venv-python> <plugin-dir>/lib/loci_stats.py summary
```

Render the footer — include the summary line only if the command produced output:
```
─── LOCI · stack-depth ─────────────────
  <N> functions analyzed
    <cumulative-summary-output>        ← omit if empty
────────────────────────────────────────
```

- **N** = unique entry functions analyzed via asm-analyze stack-depth

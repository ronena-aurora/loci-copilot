---
description: Analyze function execution timing and energy from compiled assembly
when_to_use: When user asks for timing/energy of a specific function from compiled assembly.
disable-model-invocation: true
---

# LOCI Timing Analysis

Read these values from the LOCI session context (system-reminder block at session start) and substitute them wherever the placeholders appear below:
- `asm-analyze command: <path>` → use as `<asm-analyze-cmd>`
- `venv python: <path>` → use as `<venv-python>`
- `plugin dir: <path>` → use as `<plugin-dir>`

For example, to extract assembly for a functions called `function_1` and `function_2` from `filter.elf`:
```
<asm-analyze-cmd> extract-assembly --elf-path filter.elf --functions function_1,function_2
```
The output is JSON. Use the `timing_csv`, and `timing_architecture` fields from it in step 3.
Use the `control_flow_graph` field when generating analysis results.

## Step 0: Resolve Architecture and Toolchain

Determine which LOCI target architecture and compiler to use:

1. **User's own compilation** — if the user already compiled targeting a LOCI architecture, reuse their binary. Skip directly to assembly extraction (step 2 of the full compilation path).
2. **Existing ELF/object files** — if the project already has .elf, .out, .o, or .axf files, use them directly. asm_analyze.py auto-detects architecture from the ELF.
3. **No context** — ask the user which target, or default to aarch64.

### Cross-compilation defaults

Use these defaults only when the user has no existing build:

| Architecture | Compiler | Flags | Build dir |
|---|---|---|---|
| aarch64 | `aarch64-linux-gnu-g++` | `-g -O2 -march=armv8-a` | `.loci-build/aarch64/` |
| cortexm | `arm-none-eabi-g++` | `-g -O2 -mcpu=cortex-m4 -mthumb` | `.loci-build/cortexm/` |
| tricore | `tricore-elf-g++` | `-g -O2 -mcpu=tc3xx` | `.loci-build/tricore/` |

In all steps below, replace `<arch>`, `<compiler>`, and `<flags>` with values from the resolved architecture.

Check that loci MCP is connected and authenticated — you see the tools before
running the steps that require it. If the MCP is unavailable, tell the user:

> LOCI MCP server is not connected. Run `/mcp` in Claude Code to manage
> MCP servers, then approve the **loci** server. If it does not appear,
> restart Claude Code — the plugin registers it automatically on startup.

For plugin to work mcp should be authenticated and connected.

## Incremental Path (preferred)

If a previous `.o` exists in `.loci-build/<arch>/`, use incremental compilation:

1. Save the existing `.o` as `.o.prev`
2. Compile only the changed source with `-c`.
   Always include `-g` to emit DWARF debug info (required by asm-analyze):
   ```
   <compiler> -g <flags> -c <source> -o .loci-build/<arch>/<basename>.o
   ```
3. Diff `.o.prev` vs `.o` to find changed functions:
   ```
   <asm-analyze-cmd> diff-elfs --elf-path .o.prev --comparing-elf-path .o
   ```
4. Extract assembly for only `modified`/`added` functions:
   ```
   <asm-analyze-cmd> extract-assembly --elf-path .o --functions <changed_funcs>
   ```
5. Skip to step 3 (MCP call) below.

If no `.o` exists yet, fall through to full compilation.

## Full Compilation Path

1. Cross-compile the target file for the resolved architecture:
   ```
   <compiler> <flags> -o <binary> <source>
   ```
2. Extract assembly with per-block granularity:
   ```
   <asm-analyze-cmd> extract-assembly --elf-path <binary> --functions <func> --blocks blocks.csv
   ```
   The JSON output contains `timing_csv_chunks` (list of per-block CSV chunks like `calculate_0x718,...`) and `timing_architecture`.
3. Call `mcp__loci__get_assembly_block_exec_behavior` for **all chunks
   in parallel** (one call per chunk, all in the same response):
   - `csv_text`: the chunk
   - `architecture`: the `timing_architecture` value from step 2's JSON output
   IMPORTANT: Issue all chunk calls simultaneously — do NOT call them
   sequentially. Concatenate the result CSVs (skip duplicate headers)
   before reporting.
4. If the MCP tool returns an error containing "limit reached" or "quota",
   **stop the skill entirely** — do not emit the report template or footer.
   Instead, output only:
   ```
   LOCI usage quota reached — timing analysis skipped.

   <server error message verbatim>
   ```
   Then end the skill. Do not continue to steps 5-6.
5. Report execution time and standard deviation in microseconds, and energy consumption in Watt-seconds (`energy_ws`)
6. When reporting results, 
   - note that these measurements come from LOCI's LCLM trained on real HW traces — they reflect actual silicon behavior on the target board, not theoretical IPC estimates. 
   - High std_dev indicates the assembly pattern is underrepresented in the training data; low std_dev means strong empirical backing.
   - using the annotated CFG (Control Flow Graphs) from the `control_flow_graph` field from step 2, select a most likely execution path to do performance analysis on with the timing data.
   - highlight the hottest blocks in source code if source code info is available in the annotated CFG s

## LOCI voice remark

Before the footer, add one short LOCI voice remark (max 15 words) that
acknowledges the user's work grounded in a specific number from the
analysis. Attribute improvements to the user ("clean work", "smart move",
"tight code"). For concerns, be honest and constructive with specifics.
Skip if the analysis produced no results or the user needs raw data only.

## LOCI footer

After reporting timing results, append this footer as the last thing printed —
**only if N > 0**. If no functions were processed, do NOT emit the footer.

**Record cumulative stats** (run via Bash before rendering the footer):
```
<venv-python> <plugin-dir>/lib/loci_stats.py record --skill exec-trace --functions <N> --mcp-calls <M> --co-reasoning 0
```

**Read cumulative summary** (run via Bash; capture output):
```
<venv-python> <plugin-dir>/lib/loci_stats.py summary
```

Render the footer — include the summary line only if the command produced output:
```
─── LOCI · exec-trace ──────────────────
  <N> functions · <M> MCP calls for execution behavior
    <cumulative-summary-output>        ← omit if empty
────────────────────────────────────────
```

- **N** = unique functions whose assembly was sent to LOCI
- **M** = MCP calls to `mcp__loci__get_assembly_block_exec_behavior` (exec-behaviors)


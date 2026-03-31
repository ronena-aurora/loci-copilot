---
name: loci-post-edit
description: >
  Post-edit execution analysis: after code changes, compare pre-edit and
  post-edit compiled artifacts to report execution timing % diff, energy
  consumption, and control-flow analysis for all modified/added functions.
  MUST be invoked automatically after any Edit/Write to C/C++/Rust source files
  when compiled artifacts are available — do not wait for the user to ask.
  Also invoke when the user says "analyze the change", "measure the edit",
  "post-edit", "compare before/after", "timing diff", or any time the user
  wants execution-level feedback on a code change.
---

# loci-post-edit

This skill merges execution-trace (timing/energy) and control-flow (CFG)
analysis into a single post-edit report. It compares pre-edit and post-edit
compiled artifacts to show exactly how the change affects hardware execution.


Check that loci MCP is connected and authenticated, you see the tools before
running the preflight steps that require it. If the MCP is unavailable, tell
the user:

> LOCI MCP server is not connected. Please run `/mcp` in Claude Code to
> manage MCP servers, then approve the **loci** server. If it does not
> appear, restart Claude Code — the plugin registers it automatically on
> startup.

For plugin to work mcp should be authenticated and connected.

## Step 0: Check session context

Read architecture and compiler from the LOCI session context (the
`system-reminder` block emitted at session start). Look for:

```
Target: <target>, Compiler: <compiler>, Build: <build>
LOCI target: <loci_target>
```

Map the LOCI target to loci MCP suported architectues and binary targets:

| LOCI target |   Time from CPU  |
|---|---|
| aarch64 | A53 |
| armv7e-m | CortexM4|
| armv6-m | CortexM0P |
| tc3xx | TC399 |

If the architecture is **not** in this table, emit and stop:

```

Supported: aarch64 , armv7e-m , armv6-m , tc399
```

If no compiler was detected, inform the user and stop.

Do **not** re-run detection scripts — use the values already in the session context.

## Step 1: Identify pre-edit and post-edit artifacts

Use the **session context** from step 0 (detected binaries, build system,
compiler) to locate the compiled artifact (`.o` or linked binary) for the
edited source file. Check the build output directory from the project's
build system, not just the source directory.

The preflight hook automatically saves a pre-edit snapshot as
`<name>.o.prev` next to the `.o`. If no `.o.prev` exists, proceed with
absolute timing only (no % diff). If no artifacts exist at all, note
"(no binary)" and stop.

## Step 2: diff-elfs — find modified/added functions

Use the asm-analyze command, which is a python script from lib/asm_analyze.py in the plugin dir.
Use the python version from .venv folder in the plugin dir for running python scripts.

```
<asm-analyze-cmd> diff-elfs --elf-path <pre.o> --comparing-elf-path <post.o> --arch <loci_target>
```

This returns lists of `modified` and `added` functions. Only these functions
need analysis — skip unchanged code entirely.

If there is no pre-edit artifact, treat all functions in the post-edit artifact
as "added".

## Step 3: extract-assembly (pre + post)

For **modified** functions, extract assembly from both artifacts:

```
<asm-analyze-cmd> extract-assembly --elf-path <pre.o> --functions <func1>,<func2> --arch <loci_target>
<asm-analyze-cmd> extract-assembly --elf-path <post.o> --functions <func1>,<func2> --arch <loci_target>
```

For **added** functions, extract from post-edit only:

```
<asm-analyze-cmd> extract-assembly --elf-path <post.o> --functions <new_func> --arch <loci_target>
```

The JSON output contains `timing_csv` and `timing_architecture` fields needed
for the MCP call.
The JSON also contains the `control_flow_graph` field that contains annotated CFG's in text-format optimized for LLM analysis.

the calls for extracting fields from the json output:

  data = json.load(...)
  cfg_text = data["control_flow_graph"]    # all functions, annotated CFG blocks
  timing_csv_chunks = data["timing_csv_chunks"]  # list of per-block CSV chunks for MCP
  timing_architecture = data["timing_architecture"]    # timing architecture

## Step 4: LOCI MCP timing — compute % diff

Call `mcp__loci-plugin__get_assembly_block_exec_behavior` for **all chunks in
parallel** (one call per chunk, all in the same response):
- `csv_text`: the chunk
- `architecture`: the `timing_architecture` value from step 3

IMPORTANT: Issue all chunk calls simultaneously in a single message — do NOT
call them sequentially. Concatenate the result CSVs (skip duplicate headers)
before computing metrics.

Do this for both pre-edit and post-edit assembly of modified functions, and
for post-edit only of added functions.

From the MCP response and also using the annotated CFG's from step 3, compute:
- **Happy path** = `execution_time_ns` - `std_dev`
- **Worst path** = `execution_time_ns` + `std_dev`
- **Energy** = `energy_ws` (report in uWs)

For modified functions, compute % diff:
```
diff_pct = ((post_value - pre_value) / pre_value) * 100
```

### Graceful degradation

- **LOCI MCP unavailable** — report CFG analysis only, note "(timing unavailable — MCP not connected)"
- **No pre-edit artifact** — report absolute timing only, no % diff

## Step 5: Emit report

### Modified functions

```
## Post-Edit: <FunctionName>

### Execution (<loci_target>)
                  Before          After           Diff
Happy path:   XXX.XX ns       XXX.XX ns       +X.X% | -X.X%
Worst path:   XXX.XX ns       XXX.XX ns       +X.X% | -X.X%
Energy:       XXX.XX uWs      XXX.XX uWs      +X.X% | -X.X%

### Control Flow
<brief CFG analysis from step 4>
```

### New/added functions

```
## Post-Edit: <FunctionName> (NEW)

### Execution (<loci_target>)
Happy path:   XXX.XX ns
Worst path:   XXX.XX ns
Energy:       XXX.XX uWs

### Control Flow
<CFG analysis from step 4>
```

### No pre-edit artifact (absolute only)

```
## Post-Edit: <FunctionName>

### Execution (<loci_target>)
Happy path:   XXX.XX ns
Worst path:   XXX.XX ns
Energy:       XXX.XX uWs
(no pre-edit artifact — showing absolute values only)

### Control Flow
<CFG analysis>
```

## LOCI footer

After emitting all per-function reports, append this footer once as the very
last thing printed — **only if N > 0**. If no functions were processed, do NOT emit the footer.

```
─── LOCI · post-edit ───────────────────
  <N> functions · <M> MCP calls for execution behavior
────────────────────────────────────────
```

- **N** = unique functions (modified + added) whose assembly was sent to LOCI
- **M** = MCP calls to `mcp__loci-plugin__get_assembly_block_exec_behavior` (exec-behaviors)
  (typically 2 for modified functions: pre + post; 1 for added functions)

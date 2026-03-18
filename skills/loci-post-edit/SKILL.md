---
name: loci-post-edit
description: >
  Post-edit execution analysis: after code changes, compare pre-edit and
  post-edit compiled artifacts to report execution timing % diff, energy
  consumption, and control-flow analysis for all modified/added functions.
  Invoke when the user says "analyze the change", "measure the edit",
  "post-edit", "compare before/after", "timing diff", or any time the user
  wants execution-level feedback on a code change. No safety checks — those
  stay in loci-preflight.
---

# loci-post-edit

This skill merges execution-trace (timing/energy) and control-flow (CFG)
analysis into a single post-edit report. It compares pre-edit and post-edit
compiled artifacts to show exactly how the change affects hardware execution.

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

Supported: aarch64 , armv7e-m , armv6-m , tc3xx 
```

If no compiler was detected, inform the user and stop.

Do **not** re-run detection scripts — use the values already in the session context.

## Step 1: Identify pre-edit and post-edit artifacts

The user provides or points to both pre-edit and post-edit `.o` or binary files.
These may be:
- Two `.o` files (e.g. `func.o.prev` and `func.o`)
- Two binaries/ELFs
- A single post-edit artifact (no pre-edit available)

If no pre-edit artifact exists, proceed with absolute timing only (no % diff).
If no artifacts exist at all, note "(no binary)" and stop.

## Step 2: diff-elfs — find modified/added functions

Use the asm-analyze command from the LOCI session context:

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

## Step 4: extract-cfg from post for all changed/added functions

```
<asm-analyze-cmd> extract-cfg --elf-path <post.o> --functions <all_changed_funcs> --arch <loci_target>
```

The output is text-format CFG optimized for LLM analysis.

## Step 5: LOCI MCP timing — compute % diff

Call `mcp__loci-plugin__get_assembly_block_exec_behavior` with:
- `csv_text`: the `timing_csv` value from step 3
- `architecture`: the `timing_architecture` value from step 3

Do this for both pre-edit and post-edit assembly of modified functions, and
for post-edit only of added functions.

From the MCP response, compute:
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

## Step 6: Emit report

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

---
name: loci-preflight
description: >
  MANDATORY during planning: before writing or editing any function, run
  execution-aware analysis (control-flow, timing/energy) on existing callees
  using compiled artifacts. This skill MUST be invoked during /plan mode when
  the user describes new logic to implement — do NOT skip it, do NOT wait to be
  asked. Trigger words: "implement", "add", "write a function", "new feature",
  "how should I". Do NOT invoke for direct edit requests outside of plan mode.
  The point is to catch timing and energy problems while the design is still
  cheap to change.
---

# loci-preflight

This skill is a **thinking tool, not a write-gate**. Run it during planning —
while you are still deciding what to write — so the execution fit is visible
before any code changes. The output shapes how you write, not just whether.

**Preflight requires compiled artifacts.** It does not fall back to source-level
reasoning. If the project cannot be compiled or the architecture is not
supported, the skill stops and tells the user why.

## When to run

Run preflight as part of forming your plan, immediately after you understand
what function(s) you need to write and before you issue any Edit/Write call:

1. User describes the task
2. You read the relevant files to understand the call site and surrounding code
3. **← run preflight here, while thinking**
4. Adjust the plan based on findings
5. Write the code

If you are in `/plan` mode or generating a step-by-step approach, include the
preflight report as a section of the plan before listing the edit steps.

## Step 0: Check session context

Check that loci MCP is connected and authenticated, you see the tools before
running the preflight steps that require it. If the MCP is unavailable, tell
the user:

> LOCI MCP server is not connected. Please run `/mcp` in Claude Code to
> manage MCP servers, then approve the **loci** server. If it does not
> appear, restart Claude Code — the plugin registers it automatically on
> startup.

For plugin to work mcp should be authenticated and connected.

Read architecture and compiler from the LOCI session context (the
`system-reminder` block emitted at session start). Look for:

```
Target: <target>, Compiler: <compiler>, Build: <build>
LOCI target: <loci_target>
```

Map the LOCI target to loci MCP supported architectures and binary targets:

| LOCI target | Time from CPU |
|---|---|
| aarch64 | A53 |
| armv7e-m | CortexM4 |
| armv6-m | CortexM0P |
| tc3xx | TC399 |

The CPU column identifies which real silicon hardware the LOCI timing and
energy predictions are traced from.

If the architecture is **not** in this table, emit and stop:

```
## Preflight: STOPPED
Architecture not supported.
Supported: aarch64 , armv7e-m , armv6-m , tc3xx
Preflight requires compiled artifacts — it does not fall back to source-level reasoning.
```

If no compiler was detected, emit and stop:

```
## Preflight: STOPPED
No compiler detected in session context.
Preflight requires compiled artifacts — it does not fall back to source-level reasoning.
Action: resolve the build environment, then re-run preflight.
```

Do **not** re-run detection scripts — use the values already in the session context.

## Step 1: Compile or locate artifact

The goal is to obtain a compiled artifact containing the callees the new code
will invoke. Partial compilation with `.o` files is the primary path — you do
NOT need a fully linked binary.

This works for **all supported platforms and compilers** — the `-c` flag is
universal across gcc, clang, tiarmclang, arm-none-eabi-gcc, tricore-elf-gcc,
etc. Use the compiler and target detected in Step 0.

**Primary path: `.o` partial compilation**

1. If a previous `.o` exists for the source file, save it as `.o.prev`
   (this enables delta reporting in Step 3).
2. Compile only the relevant source file with `-c`:
   ```
   <compiler> <flags> -c <source> -o <basename>.o
   ```

**Secondary path: existing binary**

Use a full binary (.elf, .out) only if the user explicitly provides one or if
the callees span multiple compilation units and linking is needed.

**Hard stop: no compilation possible**

If there is no binary, no `.o`, and compilation is not possible (missing
dependencies, build errors, etc.), the skill MUST stop:

```
## Preflight: STOPPED
No compiled artifact available and compilation is not possible.
Reason: <compilation failed: error | missing headers | missing dependencies>
Preflight requires compiled artifacts — it does not fall back to source-level reasoning.
Action: resolve the build environment, then re-run preflight.
```

Do NOT proceed with any analysis. Do NOT emit Call graph, Latency, Energy, or
Execution fit lines.

## Step 2: Call graph and timing/energy analysis

Use the asm-analyze command, which is a python script from lib/asm_analyze.py
in the plugin dir. Use the python version from .venv folder in the plugin dir
for running python scripts.

The goal is to analyze existing compiled callees — functions the new code will
call — before writing anything.

### Extract assembly

Extract CFGs for the callees the new function will invoke:

```
<asm-analyze-cmd> extract-assembly --elf-path <.o or binary> --functions <callee_1,callee_2...> --arch <loci_target>
```

The JSON contains the `control_flow_graph` field with annotated CFGs in
text-format optimized for LLM analysis.

The JSON output contains `timing_csv_chunks`, `timing_csv`, and `timing_architecture` fields needed
for the MCP call.

the calls for extracting fields from the json output:

  data = json.load(...)
  cfg_text = data["control_flow_graph"]    # all functions, annotated CFG blocks
  timing_csv_chunks = data["timing_csv_chunks"]  # list of per-block CSV chunks for MCP
  timing_architecture = data["timing_architecture"]    # timing architecture


### Timing and energy via LOCI MCP

Immediately after extraction, get hardware-accurate timing and energy for the
callees:

Call `mcp__loci-plugin__get_assembly_block_exec_behavior` for **all chunks in
parallel** (one call per chunk, all in the same response):
- `csv_text`: the chunk
- `architecture`: the `timing_architecture` field from the output above

IMPORTANT: Issue all chunk calls simultaneously in a single message — do NOT
call them sequentially. Concatenate the result CSVs (skip duplicate headers)
before computing per-callee metrics.

Compute per-callee:
- **Happy path** = `execution_time_ns` - `std_dev`
- **Worst path** = `execution_time_ns` + `std_dev`
- **Energy** = `energy_ws` (report in uWs; convert from Ws by multiplying by 1e6)

Sum worst-case timings and energy across the hot-path call chain. If the
cumulative chain exceeds a known deadline or energy budget, flag it now —
before any code is written.

If modifying an existing function and a `.o.prev` exists, also extract timing
and energy for the baseline (pre-edit) callees. Compute delta:
```
diff_pct = ((post_value - pre_value) / pre_value) * 100
```

If the MCP is unavailable, skip timing/energy and note
"(timing/energy unavailable — MCP not connected)".

### Analyze the CFG output

Check the CFG text from the extract-assembly output for structural hazards:
- **Missing declarations**: are callees present in the binary with the expected
  signatures? If a callee is absent, flag a missing forward declaration or
  linkage issue.
- **Indirect calls**: any `bl` to a register in a callee's CFG — flag as a
  potential CFI hazard.
- **Recursion/cycles**: back edges in the CFG with no visible exit condition —
  flag unbounded recursion.
- **Latency**: use the MCP timing results above; flag any callee whose worst
  path violates a timing budget, or where the cumulative hot-path chain
  exceeds a known deadline.
- **Energy**: use the MCP energy results above; flag any callee or hot-path
  chain whose energy cost is notably high relative to the use case (e.g.,
  battery-powered device, ISR context, tight power budget).

### Reason over results

After analyzing the CFG and receiving LOCI results, reason through the
following before proceeding to output. This is a mandatory thinking step —
do not skip it when results look clean. Increment **R** (reasoning cycle
counter) by 1 now.

**Interpretation questions:**
- What is this function's role in the system — is it on a hot path, ISR,
  periodic task, or called once? This determines whether any timing delta
  is critical, advisory, or irrelevant.
- If `.o.prev` exists: is `|delta| < std_dev`? If yes — change is within measurement
  noise, treat as stable. If `|delta| > std_dev` — change is real; flag it.
  If no `.o.prev`: this is the first measurement — record these numbers as the
  baseline and note no prior exists for comparison.
- Does std_dev indicate a stable path or high hardware variance — and why
  (cache sensitivity, branch misprediction, pipeline stalls visible in CFG)?
- Is a timing budget known from the session context? If yes, compare hot-path
  worst against it and flag if exceeded. If no budget is known, report the
  number and skip the fit assessment.
- What does the CFG structure explain about the timing — which blocks
  dominate, are there expensive paths the new code will always hit?
- Is the hot-path energy distribution balanced across callees, or does one
  callee dominate? If dominated, that callee is the leverage point — plan
  to cache its result, call it less frequently, or substitute a lighter alternative.
- Do any CFG findings (indirect calls, recursion, missing declarations) change
  the design — does the plan need a guard, a different callee, or a linkage fix?


**Escalation triggers (run skill inline, then reason over its results):**

*Escalate to `stack-depth`* when — increment R by 1 at trigger:
- Execution context is ISR, HWI, or interrupt callback, AND call chain
  depth > 3 levels visible in CFG, OR
- Recursion already flagged in CFG analysis above.

After stack-depth returns, reason over its results — increment R by 1:
- Does worst-case stack depth fit the HWI/ISR stack budget?
- Does any frame in the chain add cost the plan can eliminate?
- Does the plan need to restructure to reduce depth?
→ adjust plan based on conclusion before proceeding.

*Escalate to `memory-report`* when — increment R by 1 at trigger:
- The plan introduces significant new static allocations (large buffers,
  global arrays, static structs) visible from reading the source, OR
- `.o.prev` exists and the plan grows or restructures existing data sections.

After memory-report returns, reason over its results — increment R by 1:
- Does the new allocation fit within available ROM/RAM headroom?
  (answerable only if map file was provided — memory_regions shows usage %;
  without map file, report section size delta only)
- Which region is under most pressure after the change?
- Does the plan need to reduce static footprint before proceeding?
→ adjust plan based on conclusion before proceeding.

### Re-query loop

After reasoning, check whether a better candidate exists before committing to
the plan. If any of the following is true, go back to **Extract assembly** with
the alternative callees and repeat through **Reason over results**:

- Reasoning identified a lighter or safer alternative callee worth evaluating
- A flagged callee (timing violation, CFI hazard, recursion) has a named alternative
  visible in the source files already read
- Hot-path energy is dominated by one callee that may have a lighter variant
- The plan for the new function changed (different call sequence, new callees
  introduced) and those callees have not yet been measured by LOCI — re-query
  with the new callee set before finalizing the plan

Increment **R** by 1 and **M** by the number of new MCP calls for each re-query cycle.

**Cycle limit: 3 re-query iterations maximum.** If the limit is reached without
a stable plan, emit the best candidate found and note the cycle limit was hit.

**Convergence condition — exit the loop when:**
- The plan is stable (no new callees to evaluate and no unresolved flags), OR
- All remaining flags are ✗ BLOCK (require user decision, not further querying), OR
- The cycle limit is reached.

## Output format

Emit the preflight report as part of your thinking, before describing what
you will write. Keep it short when things are clean; be specific when they
are not.

```
## Preflight: <FunctionName>

### Execution (<loci_target>)

Per-callee:
  <callee_1>:  worst=XXX.XX ns   energy=X.XX uWs
  <callee_2>:  worst=XXX.XX ns   energy=X.XX uWs
Hot path total: worst=XXX.XX ns   energy=X.XX uWs

### CFG Analysis
  Missing declarations:  [OK | ⚠ <callee> absent — forward declaration or linkage issue]
  Indirect calls:        [OK | ⚠ <callee>: bl to register — potential CFI hazard]
  Recursion/cycles:      [OK | ⚠ <callee>: back edge with no visible exit condition]

Call graph:  [OK | ⚠ <issue>]
Latency:     [OK | ⚠ <callee>: worst=XXX ns exceeds budget | (timing/energy unavailable — MCP not connected)]
Energy:      [OK | ⚠ hot-path sum X.XX uWs | (timing/energy unavailable — MCP not connected)]

Execution fit: GOOD | ADJUST PLAN | STOP
→ <one sentence: what changes, if any, before writing>
```

When modifying an existing function (`.o.prev` available), add delta:
```
### Delta (vs baseline)
                Baseline        Projected       Diff
Worst path:     XXX.XX ns       XXX.XX ns       +X.X%
Energy:         XXX.XX uWs      XXX.XX uWs      +X.X%
```

Severity:
- **OK** — nothing to flag for this check
- **⚠ RISK** — likely bug or concern; adjust the plan to fix it before or during writing
- **✗ BLOCK** — almost certainly wrong; resolve with the user before writing

All-clear shorthand (use when all checks pass):
```
Preflight <FunctionName>: execution fit is good — proceeding with plan.
```

## Adjusting the plan based on findings

The value of running preflight during thinking is that findings change the
plan, not just add comments:

- A missing forward declaration → add it as a step before the function edit
- An unbounded loop in a callee → plan to add a termination guard or budget
- A callee timing violation → plan to cache the result, call asynchronously,
  or choose a lighter alternative before committing to the design
- An energy concern → plan to batch calls, use a lighter alternative, or move
  work off the hot path

Write the adjusted plan, then write the code. Do not write the code and then
note risks afterward — that defeats the purpose.

## LOCI footer

After emitting the preflight report (or all-clear shorthand), append this footer
as the last thing printed — **only if N > 0** (at least one function was sent to LOCI).
If no functions were processed (MCP unavailable or no callees to measure), do NOT emit the footer.

```
─── LOCI · preflight ───────────────────
  <N> functions · <M> MCP calls · <R> reasoning cycles
  escalated: <skills>                  ← omit line if no escalation
────────────────────────────────────────
```

- **N** = unique callee functions whose assembly was sent to LOCI
- **M** = MCP calls to `mcp__loci-plugin__get_assembly_block_exec_behavior` (exec-behaviors)
- **R** = reasoning cycles: 1 for the initial LOCI result pass, +1 for each
  re-query loop iteration, +2 for each escalated skill (stack-depth,
  memory-report) — 1 at trigger, 1 when reasoning over results
- **escalated** = space-separated list of skills called (e.g. `stack-depth · memory-report`);
  omit the line entirely if no escalation occurred

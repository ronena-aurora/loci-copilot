---
name: loci-preflight
description: >
  Pre-execution analysis: before writing or editing any function, reason
  through control-flow and timing/energy analysis on existing callees using compiled
  artifacts to assess execution fit before touching the code. Run this during
  planning — not at write time. Invoke ONLY when BOTH conditions are true: (1)
  the session is in plan mode (/plan or thinking mode), AND (2) the user is
  describing new logic to write ("write a function that...", "implement...",
  "add a method for...", "how should I..."). Do NOT invoke for direct edit
  requests outside of plan mode. Do not wait until you are at the keyboard —
  the point is to catch ordering and timing/energy problems while the design is
  still cheap to change.
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
running the preflight steps that require it. If the MCP is unavailable request
the user to authenticate it. For plugin to work mcp should be authenticated
and connected.

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

The JSON output contains `timing_csv` and `timing_architecture` fields needed
for the MCP call.

the calls for extracting fields from the json output:

  data = json.load(...)
  cfg_text = data["control_flow_graph"]    # all functions, annotated CFG blocks
  timing_csv = data["timing_csv"]          # per-block CSV for MCP
  timing_architecture = data["timing_architecture"]    # timing architecture


### Timing and energy via LOCI MCP

Immediately after extraction, get hardware-accurate timing and energy for the
callees:

Call `mcp__loci-plugin__get_assembly_block_exec_behavior` with:
- `csv_text`: the `timing_csv` field from the output above
- `architecture`: the `timing_architecture` field from the output above

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

Check the CFG output for call-ordering hazards:
- **Missing declarations**: are callees present in the binary with the expected
  signatures? If a callee is absent, flag a missing forward declaration or
  linkage issue.
- **Indirect calls**: any `bl` to a register in a callee's CFG — flag as a
  potential CFI hazard.
- **Recursion/cycles**: back edges in the CFG with no visible exit condition —
  flag unbounded recursion.
- **Call-order assumptions**: if the new function must be called after an
  `init()`, check whether the callee's CFG shows any guard or assertion
  enforcing that order. If not, flag it.
- **Dead paths**: if the expected execution path through a callee is
  unreachable in the CFG, flag it — the new code may never reach its target.
- **Latency**: use the MCP timing results above; flag any callee whose worst
  path violates a timing budget, or where the cumulative hot-path chain
  exceeds a known deadline.
- **Energy**: use the MCP energy results above; flag any callee or hot-path
  chain whose energy cost is notably high relative to the use case (e.g.,
  battery-powered device, ISR context, tight power budget).

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
- A call-order assumption → plan to add an assert or a static_assert
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
  <N> functions · <M> MCP calls for execution behavior
────────────────────────────────────────
```

- **N** = unique callee functions whose assembly was sent to LOCI
- **M** = MCP calls to `mcp__loci-plugin__get_assembly_block_exec_behavior` (exec-behaviors)

---
name: loci-preflight
description: >
  Pre-execution safety thinking: before writing or editing any function, run
  control-flow analysis on existing callees, check arithmetic ranges, and
  verify freed-resource access to see the execution fit before touching the
  code. Run this during planning — not at write time. Invoke when the user says
  "write a function that...", "implement...", "add a method for...", "how should
  I...", or any time you are about to form a plan that involves writing new
  logic. Also invoke during /plan or thinking mode. Do not wait until you are at
  the keyboard — the point is to catch ordering, range, and resource problems
  while the design is still cheap to change.
---

# loci-preflight

This skill is a **thinking tool, not a write-gate**. Run it during planning —
while you are still deciding what to write — so the execution fit is visible
before any code changes. The output shapes how you write, not just whether.

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

## The checks

### 1. Call graph (CFG analysis)
*What does the assembly-level control flow of the callees actually look like?*

Use the `asm-analyze` command from the LOCI session context. The goal is to
analyze existing compiled callees — functions the new code will call — before
writing anything. Follow the control-flow skill's workflow:

**Resolve architecture and toolchain** — in this order:
1. **User's own binary** — if already compiled, reuse it. Skip to CFG extraction.
2. **Incremental objects** — check `.loci-build/<arch>/` for existing `.o` files.
3. **Any ELF/object in the project** — scan for `.elf`, `.out`, `.o`, `.axf`.
4. **No binary** — cross-compile the relevant source file to get a binary, then
   extract. Default to aarch64 if the user hasn't specified a target:

   | Architecture | Compiler | Flags | Build dir |
   |---|---|---|---|
   | aarch64 | `aarch64-linux-gnu-g++` | `-O2 -march=armv8-a` | `.loci-build/aarch64/` |
   | cortexm | `arm-none-eabi-g++` | `-O2 -mcpu=cortex-m4 -mthumb` | `.loci-build/cortexm/` |
   | tricore | `tricore-elf-g++` | `-O2 -mcpu=tc3xx` | `.loci-build/tricore/` |

**Incremental path (preferred)** — if a previous `.o` exists:
1. Save the existing `.o` as `.o.prev`
2. Compile only the changed source with `-c`
3. Diff to find changed functions:
   ```
   <asm-analyze-cmd> diff-elfs --elf-path .o.prev --comparing-elf-path .o
   ```
4. Extract CFGs for the callees the new function will invoke:
   ```
   <asm-analyze-cmd> extract-cfg --elf-path .o --functions <callees...>
   ```

**Full path** — if no `.o` exists yet:
1. Cross-compile the relevant source file
2. Extract CFGs for the callees:
   ```
   <asm-analyze-cmd> extract-cfg --elf-path <binary> --functions <callees...>
   ```

**Analyze the CFG output** for call-ordering hazards:
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
- **Latency**: if `mcp__loci__*` is available, check response-time data for
  callees on the hot path and flag any that would violate a timing budget.

If no binary can be found or built, note "(no binary — static analysis only)"
and reason about call ordering from source instead.

### 2. Arithmetic ranges
*Can any expression produce an out-of-range value at runtime?*

Think through the value space of every arithmetic expression before writing it:
- **Overflow**: is any signed multiplication or addition bounded? If the inputs
  come from external data or a loop counter, assume worst case.
- **Unsigned wraparound**: any subtraction on a `size_t` or `unsigned` that
  could reach zero? (`size_t n = x - 1` when x == 0 wraps to SIZE_MAX.)
- **Shift hazards**: shift amount ≥ bit-width of the type; shifting a negative
  signed value.
- **Signed/unsigned mix**: comparing or combining signed and unsigned without
  an explicit cast silently promotes the signed operand.
- **Array index**: is every index either statically bounded or guarded before
  use? Note the guard location in your plan.

### 3. Freed-resource access
*Is every resource lifetime respected across all control-flow paths?*

Before writing, map the ownership of every resource the function will touch:
- **Use-after-free**: if the function deletes or frees a pointer, is there any
  path (including error paths) that later reads or writes through it?
- **Double-free**: can two code paths both free the same resource?
- **Dangling reference**: does the function return a reference or pointer to a
  local? Does it store a raw pointer to a temporary?
- **RAII gap**: if a resource is acquired mid-function, does every exit path
  (return, throw, early-return) release it? If not, name the RAII wrapper that
  should be used instead.
- **Post-move use**: after `std::move(x)`, is `x` read without first being
  reassigned?

## Output format

Emit the preflight report as part of your thinking, before describing what
you will write. Keep it short when things are clean; be specific when they
are not.

```
## Preflight: <FunctionName>

Call graph:  [OK | ⚠ <issue>]
Arithmetic:  [OK | ⚠ <issue>]
Resources:   [OK | ⚠ <issue>]

Execution fit: GOOD | ADJUST PLAN | STOP
→ <one sentence: what changes, if any, before writing>
```

Severity:
- **OK** — nothing to flag for this check
- **⚠ RISK** — likely bug; adjust the plan to fix it before or during writing
- **✗ BLOCK** — almost certainly wrong; resolve with the user before writing

All-clear shorthand (use when all checks pass):
```
Preflight <FunctionName>: execution fit is good — proceeding with plan.
```

## Adjusting the plan based on findings

The value of running preflight during thinking is that findings change the
plan, not just add comments:

- A missing forward declaration → add it as a step before the function edit
- An unsigned subtraction risk → plan to add a guard, write the guard first
- A resource lifetime gap → plan to use a RAII type; name it in the plan
- A call-order assumption → plan to add an assert or a static_assert
- An unbounded loop in a callee → plan to add a termination guard or budget

Write the adjusted plan, then write the code. Do not write the code and then
note risks afterward — that defeats the purpose.

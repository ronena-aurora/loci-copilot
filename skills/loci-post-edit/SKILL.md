---
name: loci-post-edit
description: >
  Post-change safety review: after a code agent writes or edits code, run the
  same three loci-preflight checks (call graph ordering, arithmetic ranges,
  freed-resource access) against the actual diff to verify execution fit.
  Invoke whenever the user says "review what the agent did", "check the
  changes", "post-review", "did the agent get it right", "verify the edit",
  or any time a write/edit session has just completed and the user wants
  confirmation before committing. Do not wait to be asked explicitly — if the
  context makes it clear that an agent just finished writing code, proactively
  offer to run this review.
---

# loci-post-edit

This skill applies the loci-preflight three-check framework to code that has
*already been written* — reviewing what the agent produced rather than
planning what to write. Think of it as the verification pass that closes the
write loop.

## When to run

Run immediately after a code-agent write/edit session completes, before the
user commits or continues:

1. Agent finishes its edits
2. **← run post-review here**
3. Address any findings
4. Commit (or continue)

## Step 1: Get the diff

Obtain the changed code. Prefer the narrowest scope that covers the session:

```bash
# Unstaged + staged changes (most common after an agent session)
git diff HEAD

# Or just staged
git diff --cached
```

If `git diff` is empty but files were clearly changed (e.g. new files written),
read those files directly. Extract every function body that was added or
modified.

## Step 2: Apply the three checks to each changed function

For each function that appears in the diff, run the same reasoning as
loci-preflight. Work through all three checks before moving to the next
function.

### Check 1 — Call graph ordering (CFI)

*Is the call sequence valid as written?*

- Does the function call anything that isn't declared/defined before this point
  in the translation unit? Flag missing forward declarations.
- Does the function call itself (directly or via a short chain) without a
  reachable base case? Flag unbounded recursion.
- Is there a call-order assumption (e.g. must run after `init()`) that isn't
  enforced in code? Flag the assumption.
- Any static/global initializer calling across translation-unit boundaries?
  Flag initialization-order risk.
- If `mcp__loci__*` tools are available, query the live call graph for the
  symbol to confirm real callee edges rather than guessing.

### Check 2 — Arithmetic ranges

*Can any expression produce an out-of-range value?*

- **Overflow**: signed multiplication or addition with unbounded inputs?
- **Unsigned wrap**: subtraction on `size_t` or `unsigned` that could reach
  zero? (`size_t n = x - 1` when x == 0 wraps to SIZE_MAX.)
- **Shift hazards**: shift amount ≥ bit-width of the type; shifting a negative
  signed value.
- **Signed/unsigned mix**: comparison or arithmetic combining signed and
  unsigned without an explicit cast.
- **Array index**: is every index statically bounded or guarded before use?

### Check 3 — Freed-resource access

*Is every resource lifetime respected across all control-flow paths?*

- **Use-after-free**: is there any path (including error paths) that reads or
  writes a pointer after it has been deleted/freed?
- **Double-free**: can two paths both free the same resource?
- **Dangling reference**: does the function return a reference or pointer to a
  local? Store a raw pointer to a temporary?
- **RAII gap**: does every exit path (return, throw, early-return) release
  every resource acquired mid-function?
- **Post-move use**: after `std::move(x)`, is `x` read without reassignment?

## Step 3: Emit the report

For each changed function, emit one block using this format:

```
## Post-Review: <FunctionName>

Call graph:  [OK | ⚠ RISK <detail> | ✗ BLOCK <detail>]
Arithmetic:  [OK | ⚠ RISK <detail> | ✗ BLOCK <detail>]
Resources:   [OK | ⚠ RISK <detail> | ✗ BLOCK <detail>]

Verdict: APPROVE | FLAG | REVERT
→ <one sentence: what needs to change, if anything>
```

All-clear shorthand (use when all three checks pass for all functions):

```
Post-review: all changed functions pass — execution fit confirmed. APPROVE.
```

### Verdict criteria

| Verdict | When to use |
|---|---|
| **APPROVE** | All checks pass across all changed functions |
| **FLAG** | One or more ⚠ RISK findings; code may work but needs attention before shipping |
| **REVERT** | One or more ✗ BLOCK findings; the change is likely wrong as written |

## Step 4: Follow through on findings

A FLAG or REVERT verdict means action is needed — don't just report and move on:

- **FLAG**: describe the risk clearly and offer a fix. Let the user decide
  whether to fix now or accept the risk consciously.
- **REVERT**: explain what is wrong, propose the corrected version, and wait
  for the user to confirm before making any further edits.

## Using LOCI data

If `mcp__loci__*` tools are available, use them during the review:

1. Query the call graph for each changed symbol to confirm real callee edges.
2. Check response-time data: if a changed function is on a hot path, flag a
   latency regression risk even if the logic is correct.
3. After a REVERT+fix cycle, consider running exec-trace on the repaired
   function to confirm the fix didn't introduce a timing regression.

If LOCI is unavailable, note "(static analysis only)" in the report.

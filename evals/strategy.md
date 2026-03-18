# Eval Strategy: loci-preflight and loci-after-edit

## Background

Both skills operate inside a code-change workflow where the live binary already
exists locally (`/home/melisa/BLE`). The preflight skill reasons about a
*planned* change before any edits happen. The after-edit skill compares the
binary or execution data *before* and *after* the edit to measure impact.

The goal of these evals is to catch real product issues: wrong reasoning,
missed risks, hallucinated improvements, and silent regressions.

---

## Part 1 — Dimensions to Test

### loci-preflight

| Dimension | What it tests |
|-----------|---------------|
| **Correct invocation** | Skill fires on planning keywords; does not fire on passive reads |
| **Correct function targeting** | Extracts the right symbol name and source location |
| **Call graph correctness** | Detects recursion hazards, forward-ref gaps, init-order issues |
| **Arithmetic correctness** | Catches overflow, unsigned wrap, bad shifts, signed/unsigned mix |
| **Resource safety** | Catches use-after-free, double-free, dangling refs, RAII gaps |
| **Execution-fit verdict** | GOOD / ADJUST PLAN / STOP verdict matches the real risk level |
| **Usefulness of warnings** | Warnings are specific and actionable, not generic boilerplate |
| **Ambiguity handling** | Handles duplicate symbol names, typos, missing functions gracefully |
| **Impossible goal detection** | Flags when requested change cannot achieve the stated goal |
| **Semantic-break detection** | Warns when a performance change would alter observable behavior |
| **Non-performance requests** | Still runs preflight for refactor/cleanup requests |
| **Output structure** | Report follows the required template |
| **Hallucination avoidance** | Does not invent callers, line numbers, or risks that don't exist |

### loci-after-edit

| Dimension | What it tests |
|-----------|---------------|
| **Before-state retrieval** | Correctly loads the preflight/before snapshot |
| **Diff correctness** | Before vs after values match actual measurements |
| **Improvement detection** | Correctly identifies and quantifies improvement |
| **Regression detection** | Correctly identifies and quantifies regression |
| **No-change detection** | Correctly reports "no measurable change" without inventing one |
| **Inconclusive detection** | Reports "inconclusive" when noise floor is too high |
| **Numerical correctness** | Percentage calculations are arithmetically correct |
| **Metric specificity** | Reports the right metric (cycles, ns, bytes) for the context |
| **Explanation quality** | Explains *why* the change produced the observed result |
| **Missing before-state** | Handles gracefully when no preflight snapshot exists |
| **Multi-function changes** | Reports per-function diffs when multiple functions changed |
| **Hallucination avoidance** | Does not fabricate timing numbers |

---

## Part 2 — Scenario Families

### Preflight scenarios

1. **Realistic performance improvement** — goal is achievable, no risks
2. **Unrealistic performance improvement** — goal is physically impossible
3. **Arithmetic-heavy function** — overflow or precision risk present
4. **Integer overflow / truncation** — specific overflow pattern
5. **Control-flow complexity** — deeply nested conditions or interrupt paths
6. **Resource / pointer lifetime** — pointer freed mid-function
7. **Ambiguous function name** — symbol exists in two translation units
8. **Missing function** — function does not exist anywhere in binary
9. **Typo in function name** — near-miss, closest symbol suggested
10. **Semantic-breaking change** — performance gain requires changing return value
11. **Refactor, not performance** — user asks to restructure, not optimize
12. **Safe-to-proceed** — all three checks pass, GOOD verdict
13. **ADJUST PLAN verdict** — one risk, not blocking
14. **STOP verdict** — at least one BLOCK issue

### After-edit scenarios

1. **Confirmed improvement** — measured speedup within expected range
2. **Detected regression** — measured slowdown after edit
3. **No measurable change** — delta is within noise floor
4. **Inconclusive** — high variance, cannot declare winner
5. **Exact before/after comparison** — both cycle counts present
6. **Refactor with no perf change** — code changed, timing unchanged
7. **Non-performance edit** — comment/whitespace change, no timing diff expected
8. **Missing before-state** — preflight was never run, no snapshot
9. **Multi-function edit** — two functions changed, different outcomes
10. **Mixed outcome** — latency improved, memory footprint increased

---

## Part 3 — File Structure

```
evals/
├── README.md
├── strategy.md                    ← this file
├── config/
│   └── binary.json                ← runtime config (binary path, project root, etc.)
├── preflight/
│   ├── evals.json                 ← eval cases (prompts + assertions)
│   ├── rubric.md                  ← scoring rubric
│   └── fixtures/                  ← C source snippets
└── after_edit/
    ├── evals.json
    ├── rubric.md
    └── fixtures/                  ← before/after source pairs
```

Each `evals.json` follows the schema:

```json
{
  "skill_name": "<skill-id>",
  "evals": [
    {
      "id": <int>,
      "name": "<slug>",
      "prompt": "/plan <user message>",
      "setup": {
        "binary": "<path or config ref>",
        "fixture_files": ["<relative path>"],
        "before_state": "<path or null>"
      },
      "expected_output": "<natural-language description of ideal response>",
      "assertions": [
        "<verifiable string assertion>"
      ],
      "rubric_ref": "<rubric section id>",
      "tags": ["<scenario family>"]
    }
  ]
}
```

Assertions are strings that a grader agent (or script) evaluates as
pass/fail against the actual Claude response. They should be specific
enough to automate where possible.

---

## Part 4 — Scoring Rubric (summary)

Full rubrics are in `preflight/rubric.md` and `after_edit/rubric.md`.

### Preflight — scoring categories (0–3 per category)

| Category | 3 (excellent) | 2 (adequate) | 1 (partial) | 0 (fail) |
|----------|--------------|--------------|-------------|---------|
| Correct trigger | Skill fires exactly when it should | Fires but slightly late | Fires after the edit starts | Does not fire |
| Target extraction | Correct name + file + line | Correct name only | Wrong name, right file | Wrong everything |
| Technical correctness | All three checks accurate | Two of three accurate | One accurate | None accurate |
| Warning relevance | All warnings are real and specific | Some warnings are generic | Warnings are vague | Warnings are wrong |
| Output structure | Exact template followed | Template mostly followed | Major deviations | No structure |
| Recommendation quality | Actionable and precise | Actionable but vague | Present but unhelpful | Missing |
| Hallucination avoidance | No invented facts | One minor invention | Significant invention | Fabricated output |

### After-edit — scoring categories (0–3 per category)

| Category | 3 | 2 | 1 | 0 |
|----------|---|---|---|---|
| Before-state retrieval | Correct values loaded | Values loaded with minor error | Values approximated | Not loaded |
| Diff correctness | Delta matches measurements | Delta directionally correct | Delta wrong magnitude | Wrong direction |
| Numerical correctness | Math is correct | Off by <5% | Off by <20% | Significantly wrong |
| Explanation quality | Explains mechanism | Explains outcome | Describes output only | No explanation |
| Hallucination avoidance | No invented numbers | One suspect value | Multiple suspect values | All fabricated |

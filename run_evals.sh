#!/bin/bash
# Run the LOCI plugin skill eval suite.
#
# Usage:
#   ./run_evals.sh --ble-root "C:\Playground\BLE"              # all evals
#   ./run_evals.sh --ble-root "C:\Playground\BLE" --skill char-counter  # one skill
#   ./run_evals.sh --ble-root "C:\Playground\BLE" --eval-id pf-simple-3 # one eval
#   ./run_evals.sh --ble-root "C:\Playground\BLE" --eval-id "pf-critical-*" # glob pattern
#   ./run_evals.sh --ble-root "C:\Playground\BLE" -j 4                  # 4 parallel jobs
#   ./run_evals.sh --ble-root "C:\Playground\BLE" --list                 # list all eval IDs
#   LOCI_TEST_BLE_ROOT="C:\Playground\BLE" ./run_evals.sh               # env var
#
# Each eval is run via `claude -p` with the skill's SKILL.md injected as a
# system prompt.  A second `claude -p --model sonnet` call grades the response
# against the expectations in evals.json.
#
# Results are written to eval-results/<timestamp>/.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
BLE_ROOT="${LOCI_TEST_BLE_ROOT:-}"
FILTER_SKILL=""
FILTER_EVAL_ID=""
LIST_MODE=false
MAX_JOBS=4
EVAL_TIMEOUT=120   # seconds per claude -p call
GRADE_TIMEOUT=60   # seconds per grader call

# Well-known BLE artifacts (relative to BLE_ROOT)
BLE_BASIC_BLE="examples/rtos/LP_EM_CC2340R5/ble5stack/basic_ble/freertos/ticlang/basic_ble.out"
BLE_DATA_STREAM="examples/rtos/LP_EM_CC2340R5/ble5stack/data_stream/freertos/ticlang/data_stream.out"

# ---------------------------------------------------------------------------
# Parse flags (same style as run_tests.sh)
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ble-root)   BLE_ROOT="$2"; shift 2 ;;
    --ble-root=*) BLE_ROOT="${1#*=}"; shift ;;
    --skill)      FILTER_SKILL="$2"; shift 2 ;;
    --skill=*)    FILTER_SKILL="${1#*=}"; shift ;;
    --eval-id)    FILTER_EVAL_ID="$2"; shift 2 ;;
    --eval-id=*)  FILTER_EVAL_ID="${1#*=}"; shift ;;
    -j)           MAX_JOBS="$2"; shift 2 ;;
    -j=*)         MAX_JOBS="${1#*=}"; shift ;;
    --timeout)    EVAL_TIMEOUT="$2"; shift 2 ;;
    --timeout=*)  EVAL_TIMEOUT="${1#*=}"; shift ;;
    --sequential) MAX_JOBS=1; shift ;;
    --list)       LIST_MODE=true; shift ;;
    -h|--help)
      head -15 "$0" | tail -14
      exit 0
      ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Validate
# ---------------------------------------------------------------------------
if ! command -v claude >/dev/null 2>&1; then
  echo "ERROR: 'claude' CLI not found on PATH."
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: 'jq' is required but not found."
  exit 1
fi

if [[ -z "$BLE_ROOT" ]]; then
  echo "ERROR: BLE root not configured."
  echo "  Use --ble-root <path> or set LOCI_TEST_BLE_ROOT."
  exit 1
fi
if [[ ! -d "$BLE_ROOT" ]]; then
  echo "ERROR: BLE root is not a directory: $BLE_ROOT"
  exit 1
fi

# Resolve to absolute path
BLE_ROOT="$(cd "$BLE_ROOT" && pwd)"

echo "BLE root: $BLE_ROOT"

# Check for the primary test ELF
BLE_ELF="$BLE_ROOT/$BLE_BASIC_BLE"
if [[ ! -f "$BLE_ELF" ]]; then
  echo "WARNING: Primary BLE ELF not found: $BLE_ELF"
  echo "  Some evals may fail."
fi

# ---------------------------------------------------------------------------
# MCP config — written to a temp file so claude -p can connect
# ---------------------------------------------------------------------------
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULTS_DIR="$SCRIPT_DIR/eval-results/$TIMESTAMP"
mkdir -p "$RESULTS_DIR"

MCP_CONFIG="$RESULTS_DIR/.mcp-config.json"
cat > "$MCP_CONFIG" <<'EOF'
{
  "mcpServers": {
    "loci": {
      "type": "http",
      "url": "https://dev.local.mcp.loci-dev.net/mcp"
    }
  }
}
EOF

# ---------------------------------------------------------------------------
# Formatting
# ---------------------------------------------------------------------------
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

REPORT="$RESULTS_DIR/report.md"
cat > "$REPORT" <<EOF
# Eval Report — $TIMESTAMP

| Skill | Eval | Verdict | Notes |
|-------|------|---------|-------|
EOF

echo -e "${BOLD}Skill Eval Runner${NC}  ($TIMESTAMP)"
echo "Results → $RESULTS_DIR/"
echo "Parallelism: $MAX_JOBS jobs"
echo ""

# ---------------------------------------------------------------------------
# Build session context that evals expect to be present
# ---------------------------------------------------------------------------
SESSION_CONTEXT="BLE project root: $BLE_ROOT
Primary test ELF: $BLE_ELF"

# ---------------------------------------------------------------------------
# print_error_detail — structured diagnostics for ERROR outcomes
#   $1: stage        ("claude-exec" | "timeout" | "empty-response" | "grade")
#   $2: exit code    (numeric, or empty)
#   $3: stderr file  (path, or empty string if none)
#   $4: tag          (SKILL:EVAL_ID)
#   $5: mcp config   (path, for next-steps hints)
#   $6: response file (path, for next-steps hints; may not exist yet)
# ---------------------------------------------------------------------------
print_error_detail() {
  local STAGE="$1"
  local EXIT_CODE="$2"
  local STDERR_F="$3"
  local TAG="$4"
  local MCP_CFG="${5:-}"
  local RESPONSE_F="${6:-}"

  echo "    ── Error Detail [$TAG] ──────────────────────────────────"
  echo "    Stage:    $STAGE"

  case "$STAGE" in
    claude-exec)
      echo "    Observed: claude CLI exited with code $EXIT_CODE"
      if [[ -n "$STDERR_F" && -s "$STDERR_F" ]]; then
        echo "    Stderr (first 5 lines):"
        head -5 "$STDERR_F" | sed 's/^/      /'
      else
        echo "    Stderr:   (empty)"
      fi
      echo "    Likely causes:"
      echo "      • Auth failure or expired API key"
      echo "      • Token / rate-limit exhaustion"
      echo "      • Network or DNS error reaching Anthropic API"
      echo "      • MCP server unreachable (config: ${MCP_CFG:-unknown})"
      echo "      • Claude CLI bug or version mismatch"
      echo "    Next steps:"
      echo "      1. Run 'claude -p \"hello\"' manually to verify auth"
      if [[ -n "$STDERR_F" && -s "$STDERR_F" ]]; then
        echo "      2. Inspect full stderr: cat $STDERR_F"
      fi
      echo "      3. Verify MCP server is up: curl ${MCP_CFG:+see $MCP_CFG}"
      ;;
    timeout)
      echo "    Observed: no response within ${EVAL_TIMEOUT}s (exit 124)"
      echo "    Likely causes:"
      echo "      • Anthropic backend delay or overload"
      echo "      • Very large prompt pushing context limits"
      echo "      • MCP tool call hanging (check MCP server logs)"
      echo "      • Network congestion or DNS timeout"
      echo "    Next steps:"
      echo "      1. Re-run with a higher --timeout value"
      echo "      2. Check MCP server health"
      echo "      3. Try a minimal prompt to isolate the hang"
      ;;
    empty-response)
      echo "    Observed: claude exited 0 but produced no output"
      echo "    Likely causes:"
      echo "      • Prompt triggered a content refusal with no text output"
      echo "      • System prompt conflict suppressing all output"
      echo "      • Claude CLI piping issue swallowing stdout"
      echo "    Next steps:"
      echo "      1. Run the prompt manually: claude -p \"<prompt>\" to see raw output"
      echo "      2. Simplify the system prompt and retry"
      ;;
    grade)
      echo "    Observed: grader claude call failed (exit $EXIT_CODE)"
      if [[ -n "$STDERR_F" && -s "$STDERR_F" ]]; then
        echo "    Stderr (first 5 lines):"
        head -5 "$STDERR_F" | sed 's/^/      /'
      else
        echo "    Stderr:   (empty)"
      fi
      echo "    Likely causes:"
      echo "      • Same as claude-exec errors (auth, rate limit, network)"
      echo "      • Grader prompt too large (response + expectations exceed context)"
      if [[ -n "$RESPONSE_F" ]]; then
        echo "      • Response file: $RESPONSE_F"
      fi
      echo "    Next steps:"
      if [[ -n "$RESPONSE_F" && -f "$RESPONSE_F" ]]; then
        echo "      1. Check response size: wc -c $RESPONSE_F"
      fi
      echo "      2. Re-run the grader manually against the saved response file"
      ;;
  esac
  echo "    ─────────────────────────────────────────────────────────"
}

# ---------------------------------------------------------------------------
# run_one_eval — runs a single eval (prompt + grade) and writes result files
#   Called either inline (sequential) or as a background job (parallel).
#   All output goes to a log file; the caller prints it.
# ---------------------------------------------------------------------------
run_one_eval() {
  local SKILL_NAME="$1"
  local EVAL_ID="$2"
  local PROMPT="$3"
  local EXPECTED="$4"
  local EXPECTATIONS="$5"
  local SYSTEM_PROMPT="$6"
  local MCP_CONFIG="$7"
  local RESULTS_DIR="$8"
  local EVAL_TIMEOUT="$9"
  local GRADE_TIMEOUT="${10}"
  local EVAL_FILE_NAME="${11}"
  local JOB_NUM="${12}"

  local TAG="${EVAL_FILE_NAME} > ${EVAL_ID}"
  local PROG_PFX="[${JOB_NUM}/${TOTAL}]"
  local RESPONSE_FILE="$RESULTS_DIR/${SKILL_NAME}_eval${EVAL_ID}_response.txt"
  local STDERR_FILE="$RESULTS_DIR/${SKILL_NAME}_eval${EVAL_ID}_stderr.txt"
  local GRADE_FILE="$RESULTS_DIR/${SKILL_NAME}_eval${EVAL_ID}_grade.txt"
  local VERDICT_FILE="$RESULTS_DIR/${SKILL_NAME}_eval${EVAL_ID}_verdict.txt"
  local LOG_FILE="$RESULTS_DIR/${SKILL_NAME}_eval${EVAL_ID}_log.txt"

  # Strip leading slash commands (/plan, /review, etc.) — they are
  # interactive-session affordances that don't work in claude -p.
  PROMPT=$(echo "$PROMPT" | sed 's|^/[a-zA-Z_-]* ||')

  {
    echo "${PROG_PFX} START    ${TAG}" >> "$PROGRESS_LOG"
    echo "  [$TAG] ${PROMPT:0:80}..."

    # ── Step 1: Run the eval prompt ────────────────────────────
    local CLAUDE_ARGS=(-p --dangerously-skip-permissions --mcp-config "$MCP_CONFIG")
    if [[ -n "$SYSTEM_PROMPT" ]]; then
      CLAUDE_ARGS+=(--append-system-prompt "$SYSTEM_PROMPT")
    fi

    local RESPONSE CLAUDE_EXIT=0
    echo "${PROG_PFX} RUNNING  ${TAG}" >> "$PROGRESS_LOG"
    RESPONSE=$(echo "$PROMPT" | timeout "$EVAL_TIMEOUT" claude "${CLAUDE_ARGS[@]}" 2>"$STDERR_FILE") || CLAUDE_EXIT=$?

    if [[ $CLAUDE_EXIT -ne 0 ]]; then
      if [[ $CLAUDE_EXIT -eq 124 ]]; then
        echo "    ERROR: eval timed out after ${EVAL_TIMEOUT}s"
        print_error_detail "timeout" "124" "$STDERR_FILE" "$TAG" "$MCP_CONFIG" "$RESPONSE_FILE"
        echo "TIMEOUT|eval exceeded ${EVAL_TIMEOUT}s" > "$VERDICT_FILE"
        echo "${PROG_PFX} DONE     ${TAG}  ERROR (timeout)" >> "$PROGRESS_LOG"
      else
        echo "    ERROR: claude exited with code $CLAUDE_EXIT"
        print_error_detail "claude-exec" "$CLAUDE_EXIT" "$STDERR_FILE" "$TAG" "$MCP_CONFIG" "$RESPONSE_FILE"
        echo "ERROR|claude exited with code $CLAUDE_EXIT" > "$VERDICT_FILE"
        echo "${PROG_PFX} DONE     ${TAG}  ERROR (exit ${CLAUDE_EXIT})" >> "$PROGRESS_LOG"
      fi
      [[ ! -s "$STDERR_FILE" ]] && rm -f "$STDERR_FILE"
      return
    fi
    [[ ! -s "$STDERR_FILE" ]] && rm -f "$STDERR_FILE"

    if [[ -z "$RESPONSE" ]]; then
      echo "    ERROR: claude exited 0 but returned empty response"
      print_error_detail "empty-response" "0" "" "$TAG" "$MCP_CONFIG" "$RESPONSE_FILE"
      echo "ERROR|empty response despite exit code 0" > "$VERDICT_FILE"
      echo "${PROG_PFX} DONE     ${TAG}  ERROR (empty response)" >> "$PROGRESS_LOG"
      return
    fi

    echo "$RESPONSE" > "$RESPONSE_FILE"
    local BYTES
    BYTES=$(echo "$RESPONSE" | wc -c | tr -d ' ')
    echo "    Response: ${BYTES} bytes"

    # ── Step 2: Grade the response ─────────────────────────────
    local GRADE_PROMPT="You are an eval grader. Determine if the response PASSES or FAILS.

## Eval prompt
$PROMPT

## Expected behavior
$EXPECTED"

    if [[ -n "$EXPECTATIONS" ]]; then
      GRADE_PROMPT="$GRADE_PROMPT

## Specific expectations (ALL must be met to pass)
$EXPECTATIONS"
    fi

    GRADE_PROMPT="$GRADE_PROMPT

## Actual response
$RESPONSE

## Instructions
Evaluate whether the response meets the expected behavior and all expectations.
For each expectation, note PASS or FAIL with a brief reason.

Reply in EXACTLY this format:

EXPECTATION_RESULTS:
- [PASS|FAIL] <expectation>: <reason>

VERDICT: PASS or FAIL
REASON: <one-line summary>"

    local GRADE_STDERR_FILE="$RESULTS_DIR/${SKILL_NAME}_eval${EVAL_ID}_grade_stderr.txt"
    local GRADE GRADE_EXIT=0
    GRADE=$(echo "$GRADE_PROMPT" | timeout "$GRADE_TIMEOUT" claude -p --model sonnet 2>"$GRADE_STDERR_FILE") || GRADE_EXIT=$?
    if [[ $GRADE_EXIT -ne 0 ]]; then
      echo "    GRADE ERROR: grader call failed (exit $GRADE_EXIT)"
      print_error_detail "grade" "$GRADE_EXIT" "$GRADE_STDERR_FILE" "$TAG" "$MCP_CONFIG" "$RESPONSE_FILE"
      [[ ! -s "$GRADE_STDERR_FILE" ]] && rm -f "$GRADE_STDERR_FILE"
      echo "GRADE_ERROR|grader exited with code $GRADE_EXIT" > "$VERDICT_FILE"
      echo "${PROG_PFX} DONE     ${TAG}  ERROR (grade fail)" >> "$PROGRESS_LOG"
      return
    fi
    [[ ! -s "$GRADE_STDERR_FILE" ]] && rm -f "$GRADE_STDERR_FILE"

    echo "$GRADE" > "$GRADE_FILE"

    local VERDICT REASON
    VERDICT=$(echo "$GRADE" | grep -oP 'VERDICT:\s*\K\S+' | head -1 || echo "UNKNOWN")
    REASON=$(echo "$GRADE" | grep -oP 'REASON:\s*\K.*' | head -1 || echo "could not extract reason")

    echo "${VERDICT}|${REASON}" > "$VERDICT_FILE"
    echo "${PROG_PFX} DONE     ${TAG}  ${VERDICT}" >> "$PROGRESS_LOG"

    if [[ "$VERDICT" == "PASS" ]]; then
      echo "    PASS — $REASON"
    elif [[ "$VERDICT" == "FAIL" ]]; then
      echo "    FAIL — $REASON"
      echo "    Grader explanation (first 8 lines):"
      head -8 "$GRADE_FILE" | sed 's/^/      /'
    else
      echo "    UNKNOWN — could not parse verdict"
    fi
  } > "$LOG_FILE" 2>&1
}

# ---------------------------------------------------------------------------
# Collect all evals into a job list, then run them
# ---------------------------------------------------------------------------
EVAL_FILES=$(find "$SCRIPT_DIR/skills" -name "*evals.json" 2>/dev/null | sort)

if [[ -z "$EVAL_FILES" ]]; then
  echo "No *evals.json files found under skills/"
  exit 1
fi

# Collect eval jobs as arrays of parameters
declare -a JOB_SKILLS=()
declare -a JOB_IDS=()
declare -a JOB_FILES=()
declare -a JOB_PROMPTS=()
declare -a JOB_EXPECTED=()
declare -a JOB_EXPECTATIONS=()
declare -a JOB_SYSPROMPTS=()

for EVAL_FILE in $EVAL_FILES; do
  SKILL_NAME=$(jq -r '.skill_name' "$EVAL_FILE")

  if [[ -n "$FILTER_SKILL" && "$SKILL_NAME" != "$FILTER_SKILL" ]]; then
    continue
  fi

  EVAL_COUNT=$(jq '.evals | length' "$EVAL_FILE")

  # Load skill instructions
  SKILL_DIR=$(dirname "$(dirname "$EVAL_FILE")")
  SKILL_MD="$SKILL_DIR/SKILL.md"
  SYSTEM_PROMPT=""
  if [[ -f "$SKILL_MD" ]]; then
    SYSTEM_PROMPT="You are running a skill eval. Follow the skill instructions below EXACTLY.

--- SESSION CONTEXT ---
$SESSION_CONTEXT
--- END SESSION CONTEXT ---

--- SKILL INSTRUCTIONS ---
$(cat "$SKILL_MD")
--- END SKILL INSTRUCTIONS ---"
  fi

  for (( i=0; i<EVAL_COUNT; i++ )); do
    EVAL_ID=$(jq -r ".evals[$i].id" "$EVAL_FILE")

    # shellcheck disable=SC2053
    if [[ -n "$FILTER_EVAL_ID" && "$EVAL_ID" != $FILTER_EVAL_ID ]]; then
      continue
    fi

    PROMPT=$(jq -r ".evals[$i].prompt" "$EVAL_FILE")
    EXPECTED=$(jq -r ".evals[$i].expected_output" "$EVAL_FILE")
    EXPECTATIONS=$(jq -r ".evals[$i].expectations // [] | .[]" "$EVAL_FILE" 2>/dev/null || true)

    JOB_SKILLS+=("$SKILL_NAME")
    JOB_IDS+=("$EVAL_ID")
    JOB_FILES+=("$(basename "$EVAL_FILE")")
    JOB_PROMPTS+=("$PROMPT")
    JOB_EXPECTED+=("$EXPECTED")
    JOB_EXPECTATIONS+=("$EXPECTATIONS")
    JOB_SYSPROMPTS+=("$SYSTEM_PROMPT")
  done
done

TOTAL=${#JOB_SKILLS[@]}
if [[ $TOTAL -eq 0 ]]; then
  echo "No evals matched the filters."
  exit 0
fi

if $LIST_MODE; then
  echo "Available eval IDs ($TOTAL total):"
  echo ""
  CURRENT=""
  for (( j=0; j<TOTAL; j++ )); do
    if [[ "${JOB_SKILLS[$j]}" != "$CURRENT" ]]; then
      CURRENT="${JOB_SKILLS[$j]}"
      echo -e "${CYAN}  $CURRENT${NC}"
    fi
    echo "    ${JOB_IDS[$j]}"
  done
  exit 0
fi

echo "Running $TOTAL evals..."
echo ""

# ---------------------------------------------------------------------------
# Launch jobs with concurrency limit
# ---------------------------------------------------------------------------
PROGRESS_LOG="$RESULTS_DIR/.progress"
touch "$PROGRESS_LOG"
tail -f "$PROGRESS_LOG" &
TAIL_PID=$!

RUNNING=0
declare -a PIDS=()

for (( j=0; j<TOTAL; j++ )); do
  run_one_eval \
    "${JOB_SKILLS[$j]}" \
    "${JOB_IDS[$j]}" \
    "${JOB_PROMPTS[$j]}" \
    "${JOB_EXPECTED[$j]}" \
    "${JOB_EXPECTATIONS[$j]}" \
    "${JOB_SYSPROMPTS[$j]}" \
    "$MCP_CONFIG" \
    "$RESULTS_DIR" \
    "$EVAL_TIMEOUT" \
    "$GRADE_TIMEOUT" \
    "${JOB_FILES[$j]}" \
    "$((j+1))" &

  PIDS[$j]=$!
  RUNNING=$((RUNNING + 1))

  # Throttle: wait for a slot if we hit the limit
  if (( RUNNING >= MAX_JOBS )); then
    wait -n 2>/dev/null || true
    RUNNING=$((RUNNING - 1))
  fi
done

# Wait for all remaining jobs
wait

# Give tail a moment to flush the last lines, then stop it
sleep 0.3
kill "$TAIL_PID" 2>/dev/null
wait "$TAIL_PID" 2>/dev/null
echo ""

# ---------------------------------------------------------------------------
# Collect results and print output
# ---------------------------------------------------------------------------
PASSED=0; FAILED=0; ERRORED=0
CURRENT_SKILL=""

for (( j=0; j<TOTAL; j++ )); do
  SKILL_NAME="${JOB_SKILLS[$j]}"
  EVAL_ID="${JOB_IDS[$j]}"
  EVAL_FILE_NAME="${JOB_FILES[$j]}"

  # Print skill header on change
  if [[ "$SKILL_NAME" != "$CURRENT_SKILL" ]]; then
    SKILL_EVAL_COUNT=0
    for s in "${JOB_SKILLS[@]}"; do
      [[ "$s" == "$SKILL_NAME" ]] && SKILL_EVAL_COUNT=$((SKILL_EVAL_COUNT + 1))
    done
    echo -e "${CYAN}━━━ Skill: $SKILL_NAME ($SKILL_EVAL_COUNT evals) ━━━${NC}"
    CURRENT_SKILL="$SKILL_NAME"
  fi

  # Print buffered log
  LOG_FILE="$RESULTS_DIR/${SKILL_NAME}_eval${EVAL_ID}_log.txt"
  if [[ -f "$LOG_FILE" ]]; then
    cat "$LOG_FILE"
    rm -f "$LOG_FILE"
  fi

  # Read verdict
  VERDICT_FILE="$RESULTS_DIR/${SKILL_NAME}_eval${EVAL_ID}_verdict.txt"
  if [[ ! -f "$VERDICT_FILE" ]]; then
    echo -e "  ${EVAL_FILE_NAME}  ${EVAL_ID}: ${RED}ERROR${NC} — no verdict produced"
    ERRORED=$((ERRORED + 1))
    echo "| $EVAL_FILE_NAME | $EVAL_ID | ERROR | no verdict produced |" >> "$REPORT"
    continue
  fi

  VERDICT_LINE=$(cat "$VERDICT_FILE")
  rm -f "$VERDICT_FILE"
  VERDICT="${VERDICT_LINE%%|*}"
  REASON="${VERDICT_LINE#*|}"

  if [[ "$VERDICT" == "PASS" ]]; then
    echo -e "  ${EVAL_FILE_NAME}  ${EVAL_ID}: ${GREEN}✓ PASSED${NC} — $REASON"
    PASSED=$((PASSED + 1))
  elif [[ "$VERDICT" == "FAIL" ]]; then
    echo -e "  ${EVAL_FILE_NAME}  ${EVAL_ID}: ${RED}✗ FAILED${NC} — $REASON"
    FAILED=$((FAILED + 1))
  elif [[ "$VERDICT" == "TIMEOUT" ]]; then
    echo -e "  ${EVAL_FILE_NAME}  ${EVAL_ID}: ${YELLOW}⏱ ERROR (timeout)${NC} — $REASON"
    ERRORED=$((ERRORED + 1))
  elif [[ "$VERDICT" == "ERROR" || "$VERDICT" == "GRADE_ERROR" ]]; then
    echo -e "  ${EVAL_FILE_NAME}  ${EVAL_ID}: ${RED}ERROR${NC} — $REASON"
    ERRORED=$((ERRORED + 1))
  else
    echo -e "  ${EVAL_FILE_NAME}  ${EVAL_ID}: ${YELLOW}? UNKNOWN${NC} — could not parse verdict"
    ERRORED=$((ERRORED + 1))
    VERDICT="UNKNOWN"
  fi
  echo "| $EVAL_FILE_NAME | $EVAL_ID | $VERDICT | $REASON |" >> "$REPORT"
  echo ""
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
cat >> "$REPORT" <<EOF

## Summary
- Total: $TOTAL
- Passed: $PASSED
- Failed: $FAILED
- Errors: $ERRORED
EOF

echo -e "${BOLD}━━━ Summary ━━━${NC}"
echo -e "  Total:   $TOTAL"
echo -e "  ${GREEN}Passed:  $PASSED${NC}"
echo -e "  ${RED}Failed:  $FAILED${NC}"
echo -e "  ${YELLOW}Errors:  $ERRORED${NC}"
echo ""
echo "Report: $RESULTS_DIR/report.md"

if (( FAILED + ERRORED > 0 )); then
  exit 1
fi

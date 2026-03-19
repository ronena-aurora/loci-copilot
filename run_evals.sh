#!/bin/bash
# Run the LOCI plugin skill eval suite.
#
# Usage:
#   ./run_evals.sh --ble-root "C:\Playground\BLE"              # all evals
#   ./run_evals.sh --ble-root "C:\Playground\BLE" --skill char-counter  # one skill
#   ./run_evals.sh --ble-root "C:\Playground\BLE" --eval-id 3           # one eval
#   ./run_evals.sh --ble-root "C:\Playground\BLE" -j 4                  # 4 parallel jobs
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
    -h|--help)
      head -13 "$0" | tail -12
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

  local TAG="${SKILL_NAME}:${EVAL_ID}"
  local RESPONSE_FILE="$RESULTS_DIR/${SKILL_NAME}_eval${EVAL_ID}_response.txt"
  local STDERR_FILE="$RESULTS_DIR/${SKILL_NAME}_eval${EVAL_ID}_stderr.txt"
  local GRADE_FILE="$RESULTS_DIR/${SKILL_NAME}_eval${EVAL_ID}_grade.txt"
  local VERDICT_FILE="$RESULTS_DIR/${SKILL_NAME}_eval${EVAL_ID}_verdict.txt"
  local LOG_FILE="$RESULTS_DIR/${SKILL_NAME}_eval${EVAL_ID}_log.txt"

  # Strip leading slash commands (/plan, /review, etc.) — they are
  # interactive-session affordances that don't work in claude -p.
  PROMPT=$(echo "$PROMPT" | sed 's|^/[a-zA-Z_-]* ||')

  {
    echo "  [$TAG] ${PROMPT:0:80}..."

    # ── Step 1: Run the eval prompt ────────────────────────────
    local CLAUDE_ARGS=(-p --dangerously-skip-permissions --mcp-config "$MCP_CONFIG")
    if [[ -n "$SYSTEM_PROMPT" ]]; then
      CLAUDE_ARGS+=(--append-system-prompt "$SYSTEM_PROMPT")
    fi

    local RESPONSE
    if ! RESPONSE=$(echo "$PROMPT" | timeout "$EVAL_TIMEOUT" claude "${CLAUDE_ARGS[@]}" 2>"$STDERR_FILE"); then
      local EXIT_CODE=$?
      if [[ $EXIT_CODE -eq 124 ]]; then
        echo "    TIMEOUT: eval exceeded ${EVAL_TIMEOUT}s"
        echo "TIMEOUT|eval exceeded ${EVAL_TIMEOUT}s" > "$VERDICT_FILE"
      else
        echo "    ERROR: claude exited non-zero ($EXIT_CODE)"
        echo "ERROR" > "$VERDICT_FILE"
      fi
      [[ ! -s "$STDERR_FILE" ]] && rm -f "$STDERR_FILE"
      return
    fi
    [[ ! -s "$STDERR_FILE" ]] && rm -f "$STDERR_FILE"

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

    local GRADE
    if ! GRADE=$(echo "$GRADE_PROMPT" | timeout "$GRADE_TIMEOUT" claude -p --model sonnet 2>/dev/null); then
      echo "    GRADE ERROR: grader call failed"
      echo "GRADE_ERROR" > "$VERDICT_FILE"
      return
    fi

    echo "$GRADE" > "$GRADE_FILE"

    local VERDICT REASON
    VERDICT=$(echo "$GRADE" | grep -oP 'VERDICT:\s*\K\S+' | head -1 || echo "UNKNOWN")
    REASON=$(echo "$GRADE" | grep -oP 'REASON:\s*\K.*' | head -1 || echo "could not extract reason")

    echo "${VERDICT}|${REASON}" > "$VERDICT_FILE"

    if [[ "$VERDICT" == "PASS" ]]; then
      echo "    PASS — $REASON"
    elif [[ "$VERDICT" == "FAIL" ]]; then
      echo "    FAIL — $REASON"
    else
      echo "    UNKNOWN — could not parse verdict"
    fi
  } > "$LOG_FILE" 2>&1
}

# ---------------------------------------------------------------------------
# Collect all evals into a job list, then run them
# ---------------------------------------------------------------------------
EVAL_FILES=$(find "$SCRIPT_DIR/skills" -path "*/evals/evals.json" 2>/dev/null | sort)

if [[ -z "$EVAL_FILES" ]]; then
  echo "No eval files found under skills/*/evals/"
  exit 1
fi

# Collect eval jobs as arrays of parameters
declare -a JOB_SKILLS=()
declare -a JOB_IDS=()
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

    if [[ -n "$FILTER_EVAL_ID" && "$EVAL_ID" != "$FILTER_EVAL_ID" ]]; then
      continue
    fi

    PROMPT=$(jq -r ".evals[$i].prompt" "$EVAL_FILE")
    EXPECTED=$(jq -r ".evals[$i].expected_output" "$EVAL_FILE")
    EXPECTATIONS=$(jq -r ".evals[$i].expectations // [] | .[]" "$EVAL_FILE" 2>/dev/null || true)

    JOB_SKILLS+=("$SKILL_NAME")
    JOB_IDS+=("$EVAL_ID")
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

echo "Running $TOTAL evals..."
echo ""

# ---------------------------------------------------------------------------
# Launch jobs with concurrency limit
# ---------------------------------------------------------------------------
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
    "$GRADE_TIMEOUT" &

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

# ---------------------------------------------------------------------------
# Collect results and print output
# ---------------------------------------------------------------------------
PASSED=0; FAILED=0; ERRORED=0
CURRENT_SKILL=""

for (( j=0; j<TOTAL; j++ )); do
  SKILL_NAME="${JOB_SKILLS[$j]}"
  EVAL_ID="${JOB_IDS[$j]}"

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
    echo -e "    ${RED}ERROR${NC}: no verdict produced"
    ERRORED=$((ERRORED + 1))
    echo "| $SKILL_NAME | $EVAL_ID | ERROR | no verdict produced |" >> "$REPORT"
    continue
  fi

  VERDICT_LINE=$(cat "$VERDICT_FILE")
  rm -f "$VERDICT_FILE"
  VERDICT="${VERDICT_LINE%%|*}"
  REASON="${VERDICT_LINE#*|}"

  if [[ "$VERDICT" == "PASS" ]]; then
    echo -e "    ${GREEN}✓ PASS${NC} — $REASON"
    PASSED=$((PASSED + 1))
  elif [[ "$VERDICT" == "FAIL" ]]; then
    echo -e "    ${RED}✗ FAIL${NC} — $REASON"
    FAILED=$((FAILED + 1))
  elif [[ "$VERDICT" == "TIMEOUT" ]]; then
    echo -e "    ${YELLOW}⏱ TIMEOUT${NC} — $REASON"
    ERRORED=$((ERRORED + 1))
  elif [[ "$VERDICT" == "ERROR" || "$VERDICT" == "GRADE_ERROR" ]]; then
    echo -e "    ${RED}ERROR${NC}"
    ERRORED=$((ERRORED + 1))
    REASON="$VERDICT"
  else
    echo -e "    ${YELLOW}? UNKNOWN${NC} — could not parse verdict"
    ERRORED=$((ERRORED + 1))
    VERDICT="UNKNOWN"
  fi
  echo "| $SKILL_NAME | $EVAL_ID | $VERDICT | $REASON |" >> "$REPORT"
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

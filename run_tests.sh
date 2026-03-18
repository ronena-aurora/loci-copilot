#!/bin/bash
# Run the LOCI plugin test suite.
#
# Usage:
#   ./run_tests.sh                          # full suite (unit only if no BLE configured)
#   ./run_tests.sh tests/unit/              # unit tests only
#   ./run_tests.sh -k "test_arch"           # filter by name
#   LOCI_TEST_BLE_ROOT="C:\Playground\BLE" ./run_tests.sh   # include integration + regression
#   ./run_tests.sh --ble-root "C:\Playground\BLE"            # same, via CLI
#   ./run_tests.sh --update-baselines       # regenerate regression baselines
#
# First run creates a Python 3.12 venv and installs the asmslicer wheel
# from asm-analyze-wheels/. Subsequent runs reuse the cached venv.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="${SCRIPT_DIR}/.venv"
WHEEL_DIR="${SCRIPT_DIR}/asm-analyze-wheels"
BOOTSTRAP_MARKER="${VENV_DIR}/.loci-test-ready"

# ---------------------------------------------------------------------------
# Cross-platform venv python path
# ---------------------------------------------------------------------------
venv_python() {
  if [ -x "${VENV_DIR}/Scripts/python.exe" ]; then
    echo "${VENV_DIR}/Scripts/python.exe"
  elif [ -x "${VENV_DIR}/bin/python" ]; then
    echo "${VENV_DIR}/bin/python"
  else
    echo ""
  fi
}

# ---------------------------------------------------------------------------
# Bootstrap: create venv + install deps (idempotent, skipped if marker exists)
# ---------------------------------------------------------------------------
bootstrap() {
  # Check uv
  if ! command -v uv >/dev/null 2>&1; then
    echo "ERROR: 'uv' is required but not found."
    echo "  Install: https://docs.astral.sh/uv/"
    exit 1
  fi

  # Create venv if missing
  if [ ! -d "$VENV_DIR" ]; then
    echo "Creating Python 3.12 venv..."
    uv venv --python 3.12 "$VENV_DIR"
  fi

  local vpy
  vpy="$(venv_python)"
  if [ -z "$vpy" ]; then
    echo "ERROR: Could not find Python in venv at ${VENV_DIR}"
    exit 1
  fi

  # Skip install if already bootstrapped with current wheel
  local wheel_hash=""
  if ls "${WHEEL_DIR}"/*.whl 1>/dev/null 2>&1; then
    wheel_hash=$(md5sum "${WHEEL_DIR}"/*.whl 2>/dev/null | awk '{print $1}' | sort | md5sum | awk '{print $1}')
  fi

  if [ -f "$BOOTSTRAP_MARKER" ] && [ "$(cat "$BOOTSTRAP_MARKER" 2>/dev/null)" = "$wheel_hash" ]; then
    return 0
  fi

  echo "Installing dependencies..."

  export VIRTUAL_ENV="$VENV_DIR"
  # Isolate from any globally-configured private registries
  export UV_EXTRA_INDEX_URL=""
  export UV_INDEX_URL="https://pypi.org/simple/"

  # asmslicer from local wheels
  if ls "${WHEEL_DIR}"/*.whl 1>/dev/null 2>&1; then
    uv pip install loci_service_asmslicer --find-links "${WHEEL_DIR}"
  fi

  # Runtime + test deps
  uv pip install pandas pydot unicorn pytest pytest-timeout

  # Auto-install any undeclared asmslicer transitive deps
  for _attempt in 1 2 3 4 5; do
    MISSING=$("$vpy" -c "from loci.service.asmslicer import asmslicer" 2>&1 \
      | grep "ModuleNotFoundError" | head -1 \
      | sed "s/.*No module named '\([^']*\)'.*/\1/" || true)
    if [ -z "$MISSING" ]; then
      break
    fi
    echo "  Installing undeclared dependency: ${MISSING}"
    uv pip install "$MISSING"
  done

  # Write marker
  echo "$wheel_hash" > "$BOOTSTRAP_MARKER"
  echo "Environment ready."
}

# ---------------------------------------------------------------------------
# Parse our own flags, forward the rest to pytest
# ---------------------------------------------------------------------------
PYTEST_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ble-root)
      export LOCI_TEST_BLE_ROOT="$2"
      shift 2
      ;;
    --ble-root=*)
      export LOCI_TEST_BLE_ROOT="${1#*=}"
      shift
      ;;
    --update-baselines)
      PYTEST_ARGS+=("$1")
      shift
      ;;
    *)
      PYTEST_ARGS+=("$1")
      shift
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
bootstrap

PYTHON="$(venv_python)"
echo ""
exec "$PYTHON" -m pytest "${PYTEST_ARGS[@]}"

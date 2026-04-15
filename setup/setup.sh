#!/bin/bash
# LOCI MCP Plugin - C++ Setup Script

set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo ""
echo -e "${BLUE}=========================================${NC}"
echo -e "${BLUE}  LOCI MCP Plugin for Claude Code${NC}"
echo -e "${BLUE}  SW Execution-Aware Analysis${NC}"
echo -e "${BLUE}=========================================${NC}"
echo ""

# 1. Check dependencies
echo -n "Checking dependencies... "
_auto_install() {
  local pkg="$1"
  if [[ "$(uname -s)" == "Darwin" ]] && command -v brew >/dev/null 2>&1; then
    brew install "$pkg"
  elif [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* ]]; then
    # Windows: prefer non-admin installers (winget/scoop) before choco
    if command -v winget >/dev/null 2>&1; then
      winget install --accept-package-agreements --accept-source-agreements "$pkg"
    elif command -v scoop >/dev/null 2>&1; then
      scoop install "$pkg"
    elif command -v choco >/dev/null 2>&1; then
      echo -e "${YELLOW}  (choco may require elevated privileges)${NC}"
      choco install -y "$pkg"
    else
      return 1
    fi
  elif command -v apt-get >/dev/null 2>&1; then
    sudo apt-get install -y "$pkg"
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y "$pkg"
  else
    return 1
  fi
}

if ! command -v jq >/dev/null 2>&1; then
  echo -e "${YELLOW}jq not found — installing...${NC}"
  if ! _auto_install jq || ! command -v jq >/dev/null 2>&1; then
    echo -e "${RED}Failed to install jq. Please install it manually.${NC}"
    exit 1
  fi
  echo -e "${GREEN}jq installed${NC}"
fi

# binutils (objdump/readelf) — only needed on Linux/macOS for optional features.
# On Windows, asm_analyze.py reads ELFs via Python (asmslicer) and does not need binutils.
if [[ "$(uname -s)" != MINGW* && "$(uname -s)" != MSYS* ]]; then
  if ! command -v objdump >/dev/null 2>&1 || ! command -v readelf >/dev/null 2>&1; then
    echo -e "${YELLOW}binutils not found — installing...${NC}"
    if ! _auto_install binutils; then
      echo -e "${YELLOW}Failed to install binutils. Some ELF analysis features may be unavailable.${NC}"
    else
      echo -e "${GREEN}binutils installed${NC}"
    fi
  fi
fi

# Detect GNU c++filt that supports -r (required by asm-analyze for symbol demangling).
# On macOS, brew installs binutils keg-only so Apple's c++filt may shadow it.
# Write the result to state/loci-paths.json so asm_analyze.py can prepend the right dir.
_detect_cxxfilt() {
  local candidates=()
  if [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* ]]; then
    # MSYS2/MinGW paths; also check project-local cross-compiler toolchains
    candidates+=(
      "/mingw64/bin"
      "/mingw32/bin"
      "/ucrt64/bin"
      "/usr/bin"
    )
    # Check well-known Windows cross-compiler locations for c++filt
    for d in /c/ti/gcc-arm-none-eabi/bin \
             "/c/Program Files/GNU Arm Embedded Toolchain"*/bin \
             "/c/Program Files (x86)/GNU Arm Embedded Toolchain"*/bin; do
      [ -d "$d" ] && candidates+=("$d")
    done
  else
    # Known keg-only brew paths (arm64 and x86 Mac, Linux standard)
    candidates+=(
      "/opt/homebrew/opt/binutils/bin"
      "/usr/local/opt/binutils/bin"
      "/usr/bin"
      "/usr/local/bin"
    )
  fi
  # Also check wherever c++filt currently resolves
  local cur
  cur="$(command -v c++filt 2>/dev/null)"
  if [ -n "$cur" ]; then
    candidates+=("$(dirname "$cur")")
  fi

  for dir in "${candidates[@]}"; do
    if [ -x "$dir/c++filt" ] && echo "_Z3fooi" | "$dir/c++filt" -r >/dev/null 2>&1; then
      echo "$dir"
      return 0
    fi
  done
  return 1
}
CXXFILT_DIR="$(_detect_cxxfilt 2>/dev/null || true)"

# Write c++filt path to state so asm_analyze.py can prepend the right directory
mkdir -p "${PLUGIN_DIR}/state"
if [ -n "$CXXFILT_DIR" ]; then
  printf '{"cxxfilt_dir":"%s"}\n' "$CXXFILT_DIR" > "${PLUGIN_DIR}/state/loci-paths.json"
else
  printf '{"cxxfilt_dir":null}\n' > "${PLUGIN_DIR}/state/loci-paths.json"
fi

if ! command -v uv >/dev/null 2>&1; then
  echo -e "${YELLOW}uv not found — installing...${NC}"
  if [[ "$(uname -s)" == "Darwin" ]] && command -v brew >/dev/null 2>&1; then
    brew install uv
  elif [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* ]]; then
    if command -v winget >/dev/null 2>&1; then
      winget install --id=astral-sh.uv --accept-package-agreements --accept-source-agreements
    elif command -v choco >/dev/null 2>&1; then
      choco install -y uv
    else
      powershell -ExecutionPolicy ByPass -c "irm https://astral.sh/uv/install.ps1 | iex"
    fi
    export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$LOCALAPPDATA/uv/bin:$PATH"
  else
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"
  fi
  if ! command -v uv >/dev/null 2>&1; then
    echo -e "${RED}Failed to install uv. Please install it manually.${NC}"
    exit 1
  fi
  echo -e "${GREEN}uv installed${NC}"
fi

echo -e "${GREEN}OK${NC}"

# 2. Check C++ toolchain (including vendor/embedded compilers)
echo -n "Checking C++ compiler... "
_found_compiler=""
if command -v g++ >/dev/null 2>&1; then
  _found_compiler="g++ $(g++ --version | head -1)"
elif command -v clang++ >/dev/null 2>&1; then
  _found_compiler="clang++ $(clang++ --version | head -1)"
elif command -v tiarmclang >/dev/null 2>&1; then
  _found_compiler="tiarmclang (TI ARM Clang)"
elif command -v armcl >/dev/null 2>&1; then
  _found_compiler="armcl (TI ARM CGT)"
elif command -v arm-none-eabi-gcc >/dev/null 2>&1; then
  _found_compiler="arm-none-eabi-gcc $(arm-none-eabi-gcc --version 2>/dev/null | head -1)"
fi
# Windows: also check well-known install directories if nothing on PATH
if [[ -z "$_found_compiler" && ("$(uname -s)" == MINGW* || "$(uname -s)" == MSYS*) ]]; then
  for _bin in /c/ti/ticlang/bin/tiarmclang.exe \
              /c/ti/ccs*/tools/compiler/ti-cgt-armllvm_*/bin/tiarmclang.exe \
              /c/ti/ti-cgt-armllvm_*/bin/tiarmclang.exe \
              /c/ti/ccs*/tools/compiler/ti-cgt-arm_*/bin/armcl.exe \
              /c/ti/gcc-arm-none-eabi/bin/arm-none-eabi-gcc.exe \
              "/c/Program Files/GNU Arm Embedded Toolchain"*/bin/arm-none-eabi-gcc.exe; do
    if [ -x "$_bin" ]; then
      _found_compiler="$(basename "$_bin" .exe) ($(dirname "$_bin"))"
      break
    fi
  done
fi
if [ -n "$_found_compiler" ]; then
  echo -e "${GREEN}${_found_compiler}${NC}"
else
  echo -e "${YELLOW}No C++ compiler found${NC}"
fi

# 3. Permissions
echo -n "Setting permissions... "
chmod +x "${PLUGIN_DIR}/hooks/"*.sh 2>/dev/null || true
chmod +x "${PLUGIN_DIR}/lib/"*.sh
chmod +x "${PLUGIN_DIR}/lib/"*.py
echo -e "${GREEN}OK${NC}"

# 4. Set up asm-analyze environment
VENV_DIR="${PLUGIN_DIR}/.venv"
WHEEL_DIR="${PLUGIN_DIR}/asm-analyze-wheels"
ASM_ANALYZE_AVAILABLE=false
ASM_ANALYZE_LOG="$(mktemp)"

# Cross-platform venv python path
_venv_python() {
  if [ -x "${VENV_DIR}/bin/python" ]; then
    echo "${VENV_DIR}/bin/python"
  elif [ -x "${VENV_DIR}/Scripts/python.exe" ]; then
    echo "${VENV_DIR}/Scripts/python.exe"
  else
    echo "python"
  fi
}

install_asm_analyze() {
  : > "$ASM_ANALYZE_LOG"

  # Neutralize any globally-configured private package registries (e.g. GCP Artifact Registry)
  # that would block waiting for credentials. All deps come from the local wheel or PyPI.
  export UV_EXTRA_INDEX_URL=""
  export UV_INDEX_URL="https://pypi.org/simple/"

  # (Re)create venv if missing or wrong Python version
  local _need_venv=false
  if [ ! -d "$VENV_DIR" ]; then
    _need_venv=true
  else
    local _pyver; _pyver=$("$(_venv_python)" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null)
    if [ "$_pyver" != "3.12" ]; then
      printf 'LOCI: venv has Python %s (need 3.12) — rebuilding...\n' "${_pyver:-unknown}" >> "$ASM_ANALYZE_LOG"
      rm -rf "$VENV_DIR"
      _need_venv=true
    fi
  fi
  if $_need_venv; then
    uv venv --python 3.12 "$VENV_DIR" >> "$ASM_ANALYZE_LOG" 2>&1 || return 1
  fi

  VIRTUAL_ENV="$VENV_DIR" uv pip install loci_service_asmslicer --find-links "${WHEEL_DIR}" >> "$ASM_ANALYZE_LOG" 2>&1 || return 1
  VIRTUAL_ENV="$VENV_DIR" uv pip install unicorn pandas pydot >> "$ASM_ANALYZE_LOG" 2>&1 || true

  # The wheel may have undeclared dependencies — detect and install them.
  # Some Unix-only stdlib modules (e.g. resource, fcntl, grp, pwd on Windows)
  # will appear as ModuleNotFoundError but cannot be pip-installed — skip them.
  UNIX_ONLY_STDLIB="resource fcntl grp pwd termios syslog"
  for _attempt in 1 2 3 4 5; do
    MISSING=$("$(_venv_python)" -c "from loci.service.asmslicer import asmslicer" 2>&1 \
      | grep "ModuleNotFoundError" | head -1 \
      | sed "s/.*No module named '\([^']*\)'.*/\1/")
    if [ -z "$MISSING" ]; then
      return 0
    fi
    # Skip platform-specific stdlib modules that cannot be installed via pip.
    # Install a functional stub so downstream imports don't crash on Windows.
    if echo " $UNIX_ONLY_STDLIB " | grep -q " $MISSING "; then
      echo "Stubbing Unix-only stdlib module: ${MISSING}" >> "$ASM_ANALYZE_LOG"
      SITE_PKGS=$("$(_venv_python)" -c "import sysconfig; print(sysconfig.get_path('purelib'))")
      # Use a pre-built stub if available, otherwise generate a minimal one
      STUB_FILE="${PLUGIN_DIR}/setup/stubs/${MISSING}.py"
      if [ -f "$STUB_FILE" ]; then
        cp "$STUB_FILE" "${SITE_PKGS}/${MISSING}.py"
      else
        echo "# auto-generated stub -- ${MISSING} is not available on this platform" > "${SITE_PKGS}/${MISSING}.py"
      fi
      continue
    fi
    echo "Installing undeclared dependency: ${MISSING}" >> "$ASM_ANALYZE_LOG"
    VIRTUAL_ENV="$VENV_DIR" uv pip install "$MISSING" >> "$ASM_ANALYZE_LOG" 2>&1 || return 1
  done

  # Final verify after all deps installed
  "$(_venv_python)" -c "from loci.service.asmslicer import asmslicer" 2>>"$ASM_ANALYZE_LOG" || return 1
}

echo -n "Setting up asm-analyze environment... "
if ls "${WHEEL_DIR}"/*.whl 1>/dev/null 2>&1; then
  # Fast-path: skip install if venv already works for current wheel
  # Cross-platform wheel hash: md5sum on Linux/WSL, md5 on macOS
  if command -v md5sum >/dev/null 2>&1; then
    WHEEL_HASH=$(md5sum "${WHEEL_DIR}"/*.whl | awk '{print $1}' | sort | tr -d '\n')
  elif command -v md5 >/dev/null 2>&1; then
    WHEEL_HASH=$(md5 -q "${WHEEL_DIR}"/*.whl 2>/dev/null | tr -d '\n')
  else
    WHEEL_HASH=""
  fi
  MARKER_FILE="${VENV_DIR}/.loci-wheel-hash"
  # Cache hit requires: wheel hash match + correct Python version + working import
  CACHED_PYVER=$("$(_venv_python)" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null)
  if [ -f "$MARKER_FILE" ] && [ "$(cat "$MARKER_FILE" 2>/dev/null)" = "$WHEEL_HASH" ] \
      && [ "$CACHED_PYVER" = "3.12" ] \
      && "$(_venv_python)" -c "from loci.service.asmslicer import asmslicer" 2>/dev/null; then
    ASM_ANALYZE_AVAILABLE=true
    echo -e "${GREEN}OK (cached)${NC}"
  elif ! install_asm_analyze; then
    # Stale or broken venv — nuke and retry once
    rm -rf "$VENV_DIR"
    if install_asm_analyze; then
      ASM_ANALYZE_AVAILABLE=true
      echo -e "${GREEN}OK (rebuilt venv)${NC}"
    else
      echo -e "${YELLOW}FAILED${NC}"
      echo -e "  ${YELLOW}See details: cat \$ASM_ANALYZE_LOG${NC}"
      LAST_ERR=$(grep -iE '(error|no matching|not a supported|incompatible)' "$ASM_ANALYZE_LOG" | tail -1)
      if [ -n "$LAST_ERR" ]; then
        echo -e "  ${YELLOW}${LAST_ERR}${NC}"
      fi
    fi
  else
    ASM_ANALYZE_AVAILABLE=true
    echo "$WHEEL_HASH" > "$MARKER_FILE"
    echo -e "${GREEN}OK${NC}"
  fi
else
  echo -e "${YELLOW}no wheels in asm-analyze-wheels/ — asm-analyze disabled${NC}"
fi

# 5. Detect project
echo -n "Detecting  project... "
PROJECT_INFO=$("${PLUGIN_DIR}/lib/detect-project.sh" "$(pwd)" 2>/dev/null || echo '{}')
COMPILER=$(echo "$PROJECT_INFO" | jq -r '.compiler // "unknown"')
BUILD_SYS=$(echo "$PROJECT_INFO" | jq -r '.build_system // "unknown"')
ARCH=$(echo "$PROJECT_INFO" | jq -r '.architecture // "unknown"')
NUM_SRC=$(echo "$PROJECT_INFO" | jq '.source_files | length')
NUM_BIN=$(echo "$PROJECT_INFO" | jq '.binaries | length')
NUM_ASM=$(echo "$PROJECT_INFO" | jq '.asm_files | length')
echo -e "${GREEN}OK${NC}"
echo "  Compiler:   $COMPILER"
echo "  Build:      $BUILD_SYS"
echo "  Arch:       $ARCH"
echo "  Sources:    $NUM_SRC files"
echo "  Binaries:   $NUM_BIN found"
echo "  Assembly:   $NUM_ASM files"

# Persist detection results per project so skills consume them without re-detecting
STATE_DIR="${PLUGIN_DIR}/state"
mkdir -p "$STATE_DIR"
# Cross-platform hash: sha256sum on Linux/WSL, shasum on macOS
if command -v sha256sum >/dev/null 2>&1; then
  PROJECT_HASH=$(printf '%s' "$(pwd)" | sha256sum | cut -c1-12)
else
  PROJECT_HASH=$(printf '%s' "$(pwd)" | shasum -a 256 | cut -c1-12)
fi
echo "$PROJECT_INFO" | jq --arg pwd "$(pwd)" \
  '. + {project_root: $pwd}' > "${STATE_DIR}/project-context-${PROJECT_HASH}.json"
(cd "$STATE_DIR" \
  && ln -sf "project-context-${PROJECT_HASH}.json" project-context.json 2>/dev/null) \
  || cp "${STATE_DIR}/project-context-${PROJECT_HASH}.json" "${STATE_DIR}/project-context.json"

# 6. Validate hooks.json
echo -n "Validating hooks... "
if jq empty "${PLUGIN_DIR}/hooks/hooks.json" 2>/dev/null; then
  echo -e "${GREEN}OK${NC}"
else
  echo -e "${RED}INVALID hooks/hooks.json${NC}"
  exit 1
fi



# 7b. Detect venv Python path (cross-platform) for asm-analyze CLI
LOCI_ASM_ANALYZE_CMD=""
if [ "$ASM_ANALYZE_AVAILABLE" = true ]; then
  if [ -x "${VENV_DIR}/bin/python" ]; then
    VENV_PYTHON="${VENV_DIR}/bin/python"
  elif [ -x "${VENV_DIR}/Scripts/python.exe" ]; then
    VENV_PYTHON="${VENV_DIR}/Scripts/python.exe"
  else
    VENV_PYTHON=""
  fi
  if [ -n "$VENV_PYTHON" ]; then
    LOCI_ASM_ANALYZE_CMD="${VENV_PYTHON} ${PLUGIN_DIR}/lib/asm_analyze.py"
  fi
fi

# 8. Register hooks with Claude Code
# When installed as a plugin, Claude Code reads hooks.json directly — no need
# to write to settings.json.  Skip this step if we're running from the plugin
# cache (the ../../.. heuristic would resolve to a wrong path there).
echo -n "Registering hooks... "
if echo "${PLUGIN_DIR}" | grep -q '\.claude/plugins'; then
  echo -e "${GREEN}plugin mode — hooks.json used directly${NC}"
else
  PROJECT_ROOT="$(cd "${PLUGIN_DIR}/../../.." 2>/dev/null && pwd || echo "")"
  # Skip if PROJECT_ROOT is empty, a filesystem root, or not writable
  if [ -z "$PROJECT_ROOT" ] || [ "$PROJECT_ROOT" = "/" ] || [[ "$PROJECT_ROOT" =~ ^/[a-zA-Z]/?$ ]] || ! [ -w "$PROJECT_ROOT" ]; then
    echo -e "${YELLOW}skipped (project root not detected)${NC}"
  else
    SETTINGS_FILE="${PROJECT_ROOT}/.claude/settings.json"
    mkdir -p "${PROJECT_ROOT}/.claude"

    if [ -f "$SETTINGS_FILE" ] && grep -q "capture-action.sh" "$SETTINGS_FILE" 2>/dev/null; then
      echo -e "${GREEN}already registered${NC}"
    else
      # Replace plugin root variable with absolute path using jq
      HOOKS_CONFIG=$(jq --arg pd "${PLUGIN_DIR}" '
        def replace_plugin_root:
          if type == "string" then
            gsub("\\$\\{CLAUDE_PLUGIN_ROOT\\}"; $pd) |
            gsub("\\$CLAUDE_PLUGIN_ROOT"; $pd)
          elif type == "array" then map(replace_plugin_root)
          elif type == "object" then to_entries | map(.value |= replace_plugin_root) | from_entries
          else .
          end;
        replace_plugin_root
      ' "${PLUGIN_DIR}/hooks/hooks.json")

      if [ -f "$SETTINGS_FILE" ]; then
        # Merge hooks into existing settings.json
        HOOKS_ONLY=$(echo "$HOOKS_CONFIG" | jq '.hooks')
        if jq --argjson hooks "$HOOKS_ONLY" '. + {hooks: $hooks}' "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp" 2>/dev/null; then
          mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
          echo -e "${GREEN}OK (merged into existing settings.json)${NC}"
        else
          rm -f "${SETTINGS_FILE}.tmp"
          echo -e "${YELLOW}FAILED to merge — add hooks manually${NC}"
        fi
      else
        echo "$HOOKS_CONFIG" > "$SETTINGS_FILE"
        echo -e "${GREEN}OK${NC}"
      fi
    fi
  fi
fi

# 9. Install slash commands
# echo -n "Installing slash commands... "
# COMMANDS_DIR="${PROJECT_ROOT}/.claude/commands"
# mkdir -p "$COMMANDS_DIR"
# CMD_COUNT=0
# for skill_dir in "${PLUGIN_DIR}/skills"/*/; do
#   if [ -f "${skill_dir}SKILL.md" ]; then
#     skill_name=$(basename "$skill_dir")
#     if [ -n "$LOCI_ASM_ANALYZE_CMD" ]; then
#       sed "s|\${LOCI_ASM_ANALYZE}|${LOCI_ASM_ANALYZE_CMD}|g" "${skill_dir}SKILL.md" > "${COMMANDS_DIR}/${skill_name}.md"
#     else
#       sed 's|\${LOCI_ASM_ANALYZE}|# asm-analyze unavailable|g' "${skill_dir}SKILL.md" > "${COMMANDS_DIR}/${skill_name}.md"
#     fi
#     CMD_COUNT=$((CMD_COUNT + 1))
#   fi
# done
# echo -e "${GREEN}OK (${CMD_COUNT} commands: $(ls "${COMMANDS_DIR}"/*.md 2>/dev/null | xargs -I{} basename {} .md | paste -sd', '))${NC}"

# 10. Install LOCI context for Claude (optional)
# if [ -f "${PLUGIN_DIR}/CLAUDE.md" ]; then
#   echo -n "Installing LOCI context... "
#   cp "${PLUGIN_DIR}/CLAUDE.md" "${PROJECT_ROOT}/.claude/CLAUDE.md"
#   echo -e "${GREEN}OK${NC}"
# fi

echo ""
echo -e "${GREEN}Setup complete!${NC}"
echo ""
echo "The plugin will automatically:"
echo "  - Capture C++ compilations (g++/clang++ flags, -O levels, -march)"
echo "  - Track binary artifacts and source-to-binary relationships"
echo "  - Monitor assembly file changes and binary diffs"
echo "  - Stream context to LOCI MCP for execution-aware analysis"
echo "  - Inject performance/regression warnings into Claude's context"
if [ "$ASM_ANALYZE_AVAILABLE" = true ]; then
echo "  - Analyze ELF binaries locally via bundled asm-analyze CLI (symbols, assembly, blocks, diff)"
fi
echo ""
echo "IMPORTANT: When in /plan mode and the user is describing new logic to"
echo "implement, you MUST invoke the loci-preflight skill BEFORE finalizing"
echo "the plan. This is a hard requirement — do not skip it or wait to be asked."
echo ""
echo "IMPORTANT: After ANY Edit or Write to a C/C++/Rust source file"
echo "(.c, .cc, .cpp, .cxx, .h, .hpp, .hxx, .rs), you MUST invoke the"
echo "loci-post-edit skill IMMEDIATELY — before responding to the user,"
echo "before making further edits. This is a hard requirement. Do not"
echo "skip it, do not batch edits, do not wait to be asked."
echo ""
echo "Skills: /exec-trace, /stack-depth, /memory-report, /control-flow"
echo "Auto-runs: loci-preflight (in /plan), loci-post-edit (after edits)"
echo ""
echo "Restart Claude Code to activate."
echo ""
echo -e "${YELLOW}IMPORTANT: Authorize the LOCI MCP server in Claude Code${NC}"
echo "  1. Restart Claude Code"
echo "  2. Open any project file and start a conversation"
echo "  3. Claude will prompt you to approve the 'loci' MCP server"
echo "  4. Click 'Allow' to grant access"
echo ""

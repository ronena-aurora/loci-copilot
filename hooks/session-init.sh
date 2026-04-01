#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# LOCI plugin — automatic setup & session initializer
# ──────────────────────────────────────────────────────────────────────────────
# Runs at every SessionStart via hooks/hooks.json.
#
# First run  : installs deps → creates venv → detects project       (~20-40 s)
# After that : re-detects project and refreshes context              (< 2 s)
#
# ALWAYS exits 0 — a failing hook must never block a session.
# Works on Linux, macOS, and Windows (MSYS2/Git Bash).
# ──────────────────────────────────────────────────────────────────────────────

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="${PLUGIN_DIR}/state"
VENV_DIR="${PLUGIN_DIR}/.venv"
WHEEL_DIR="${PLUGIN_DIR}/asm-analyze-wheels"
SETUP_MARKER="${PLUGIN_DIR}/.setup-complete"

IS_WINDOWS=false
[[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* ]] && IS_WINDOWS=true

# ── 1. PATH augmentation ─────────────────────────────────────────────────────
# Hook sub-processes don't inherit the login-shell PATH.  Prepend every common
# location where user-installed tools (uv, jq, Python, brew, etc.) live.
for _d in \
    "$HOME/.local/bin" \
    "$HOME/.cargo/bin" \
    "/usr/local/bin" \
    "/opt/homebrew/bin" \
    "/opt/homebrew/opt/binutils/bin"; do
    [ -d "$_d" ] && case ":$PATH:" in *":$_d:"*) ;; *) PATH="$_d:$PATH" ;; esac
done
if $IS_WINDOWS; then
    for _d in \
        "${LOCALAPPDATA:-$HOME/AppData/Local}/uv/bin" \
        "/mingw64/bin" "/ucrt64/bin" "/usr/bin"; do
        [ -d "$_d" ] && case ":$PATH:" in *":$_d:"*) ;; *) PATH="$_d:$PATH" ;; esac
    done
fi
export PATH

# ── 2. Helpers ────────────────────────────────────────────────────────────────

_venv_python() {
    if   [ -x "${VENV_DIR}/bin/python" ];        then echo "${VENV_DIR}/bin/python"
    elif [ -x "${VENV_DIR}/Scripts/python.exe" ]; then echo "${VENV_DIR}/Scripts/python.exe"
    else echo "python3"; fi
}

_hash_cwd() {
    local h
    h=$(printf '%s' "$(pwd)" | sha256sum 2>/dev/null | cut -c1-12)
    [ -n "$h" ] && { echo "$h"; return 0; }
    h=$(printf '%s' "$(pwd)" | shasum -a 256 2>/dev/null | cut -c1-12)
    [ -n "$h" ] && { echo "$h"; return 0; }
    printf '%s' "$(pwd)" | cksum | awk '{print $1}'
}

_plugin_version() {
    local jq_bin="$1"
    "$jq_bin" -r '.plugins[0].version // "0"' \
        "${PLUGIN_DIR}/.claude-plugin/marketplace.json" 2>/dev/null || echo "0"
}

# ── 3. Locate / auto-install jq ──────────────────────────────────────────────

_find_jq() {
    for _c in jq /usr/bin/jq /usr/local/bin/jq /opt/homebrew/bin/jq \
              "$HOME/.local/bin/jq"; do
        if command -v "$_c" >/dev/null 2>&1; then echo "$_c"; return 0; fi
        [ "$_c" != jq ] && [ -x "$_c" ] && { echo "$_c"; return 0; }
    done
    return 1
}

_install_jq() {
    printf 'LOCI: installing jq...\n'
    if [[ "$(uname -s)" == "Darwin" ]] && command -v brew >/dev/null 2>&1; then
        HOMEBREW_NO_AUTO_UPDATE=1 brew install jq >/dev/null 2>&1
    elif $IS_WINDOWS && command -v pacman >/dev/null 2>&1; then
        pacman -S --noconfirm jq >/dev/null 2>&1
    elif command -v apt-get >/dev/null 2>&1; then
        sudo -n apt-get install -y jq >/dev/null 2>&1   # -n = non-interactive
    elif command -v dnf >/dev/null 2>&1; then
        sudo -n dnf install -y jq >/dev/null 2>&1
    fi
    _find_jq   # re-check
}

JQ=$(_find_jq) || JQ=$(_install_jq) || {
    printf 'LOCI: jq not found — install with: apt-get install jq  or  brew install jq\n' >&2
    exit 0
}

mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

# ── 4. First-time setup ──────────────────────────────────────────────────────
# Guarded by a version-stamped marker.  Runs once after install or plugin
# upgrade; skipped entirely on subsequent sessions.

_detect_cxxfilt() {
    local candidates=()
    if $IS_WINDOWS; then
        candidates+=(/mingw64/bin /mingw32/bin /ucrt64/bin /usr/bin)
        for d in /c/ti/gcc-arm-none-eabi/bin \
                 "/c/Program Files/GNU Arm Embedded Toolchain"*/bin \
                 "/c/Program Files (x86)/GNU Arm Embedded Toolchain"*/bin; do
            [ -d "$d" ] && candidates+=("$d")
        done
    else
        candidates+=(
            /opt/homebrew/opt/binutils/bin /usr/local/opt/binutils/bin
            /usr/bin /usr/local/bin
        )
    fi
    local cur; cur="$(command -v c++filt 2>/dev/null)"
    [ -n "$cur" ] && candidates+=("$(dirname "$cur")")
    for dir in "${candidates[@]}"; do
        if [ -x "$dir/c++filt" ] && echo "_Z3fooi" | "$dir/c++filt" -r >/dev/null 2>&1; then
            echo "$dir"; return 0
        fi
    done
    return 1
}

_install_uv() {
    command -v uv >/dev/null 2>&1 && return 0
    printf 'LOCI: installing uv...\n'
    if [[ "$(uname -s)" == "Darwin" ]] && command -v brew >/dev/null 2>&1; then
        HOMEBREW_NO_AUTO_UPDATE=1 brew install uv >/dev/null 2>&1
    elif $IS_WINDOWS; then
        if command -v winget >/dev/null 2>&1; then
            winget install --accept-package-agreements --accept-source-agreements astral-sh.uv \
                >/dev/null 2>&1
        elif command -v scoop >/dev/null 2>&1; then
            scoop install uv >/dev/null 2>&1
        else
            powershell -ExecutionPolicy ByPass -c \
                "irm https://astral.sh/uv/install.ps1 | iex" >/dev/null 2>&1
        fi
        export PATH="${LOCALAPPDATA:-$HOME/AppData/Local}/uv/bin:$HOME/.cargo/bin:$PATH"
    else
        curl -LsSf https://astral.sh/uv/install.sh 2>/dev/null | sh >/dev/null 2>&1
        export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"
    fi
    command -v uv >/dev/null 2>&1
}

_setup_venv() {
    # Fast-path: venv already valid?
    local vpy; vpy=$(_venv_python)
    [ -x "$vpy" ] && "$vpy" -c "from loci.service.asmslicer import asmslicer" 2>/dev/null \
        && return 0

    printf 'LOCI: setting up asm-analyze environment...\n'

    # Neutralize private registries that would block on credentials
    export UV_EXTRA_INDEX_URL=""
    export UV_INDEX_URL="https://pypi.org/simple/"

    # (Re)create venv
    rm -rf "$VENV_DIR"
    uv venv --python 3.12 "$VENV_DIR" >/dev/null 2>&1 || return 1

    VIRTUAL_ENV="$VENV_DIR" uv pip install loci_service_asmslicer \
        --find-links "${WHEEL_DIR}" >/dev/null 2>&1 || return 1
    VIRTUAL_ENV="$VENV_DIR" uv pip install unicorn pandas pydot >/dev/null 2>&1 || true

    # Resolve undeclared transitive deps (up to 5 rounds)
    vpy=$(_venv_python)
    local UNIX_ONLY="resource fcntl grp pwd termios syslog"
    local _attempt MISSING
    for _attempt in 1 2 3 4 5; do
        MISSING=$("$vpy" -c "from loci.service.asmslicer import asmslicer" 2>&1 \
            | grep "ModuleNotFoundError" | head -1 \
            | sed "s/.*No module named '\([^']*\)'.*/\1/")
        [ -z "$MISSING" ] && return 0
        # Stub Unix-only stdlib modules on Windows
        if echo " $UNIX_ONLY " | grep -q " $MISSING "; then
            local sp; sp=$("$vpy" -c "import sysconfig; print(sysconfig.get_path('purelib'))")
            local stub="${PLUGIN_DIR}/setup/stubs/${MISSING}.py"
            if [ -f "$stub" ]; then cp "$stub" "${sp}/${MISSING}.py"
            else echo "# stub — ${MISSING} unavailable on this platform" > "${sp}/${MISSING}.py"
            fi
            continue
        fi
        VIRTUAL_ENV="$VENV_DIR" uv pip install "$MISSING" >/dev/null 2>&1 || return 1
    done

    "$vpy" -c "from loci.service.asmslicer import asmslicer" 2>/dev/null
}

_first_time_setup() {
    local ver; ver=$(_plugin_version "$JQ")
    [ -f "$SETUP_MARKER" ] && [ "$(cat "$SETUP_MARKER" 2>/dev/null)" = "$ver" ] && return 0

    # Simple mkdir lock prevents parallel sessions from corrupting the venv
    local lock="${PLUGIN_DIR}/.setup-lock"
    mkdir "$lock" 2>/dev/null || return 0     # another instance is setting up
    # shellcheck disable=SC2064
    trap "rmdir '$lock' 2>/dev/null" EXIT

    printf 'LOCI: first-time setup (v%s)...\n' "$ver"

    # ── permissions ──────────────────────────────────────────────────────
    chmod +x "${PLUGIN_DIR}/hooks/"*.sh 2>/dev/null || true
    chmod +x "${PLUGIN_DIR}/lib/"*.sh  2>/dev/null || true
    chmod +x "${PLUGIN_DIR}/lib/"*.py  2>/dev/null || true

    # ── c++filt → loci-paths.json ────────────────────────────────────────
    local cxdir; cxdir=$(_detect_cxxfilt 2>/dev/null || true)
    if [ -n "$cxdir" ]; then
        printf '{"cxxfilt_dir":"%s"}\n' "$cxdir" > "${STATE_DIR}/loci-paths.json"
    else
        printf '{"cxxfilt_dir":null}\n' > "${STATE_DIR}/loci-paths.json"
    fi

    # ── venv + asm-analyze (non-fatal) ───────────────────────────────────
    if ls "${WHEEL_DIR}"/*.whl 1>/dev/null 2>&1; then
        if _install_uv && _setup_venv; then
            printf 'LOCI: asm-analyze ready\n'
        else
            printf 'LOCI: asm-analyze unavailable (will retry next session)\n'
            # Don't write marker — retry on next session
            rmdir "$lock" 2>/dev/null; trap - EXIT
            return 0
        fi
    fi

    echo "$ver" > "$SETUP_MARKER"
    printf 'LOCI: setup complete\n'

    # First-run welcome — only prints once after initial install
    printf '\nWelcome to LOCI!\n\n'
    printf 'Try these:\n'
    printf '  "What'\''s the execution cost of main()?"        → timing & energy\n'
    printf '  "How much ROM/RAM does my build use?"          → memory report\n'
    printf '  "Is my stack safe for TaskMain?"               → stack depth\n'
    printf '\nLOCI auto-runs during /plan (preflight) and after edits (post-edit).\n'
    printf '\nNote: Authorize the LOCI MCP server when prompted to enable timing/energy analysis.\n'

    rmdir "$lock" 2>/dev/null; trap - EXIT
}

# ── 5. Per-session project detection ──────────────────────────────────────────
# Always runs — refreshes state/project-context.json for the current cwd.

_detect_and_write_context() {
    local PROJECT_INFO
    PROJECT_INFO=$("${PLUGIN_DIR}/lib/detect-project.sh" "$(pwd)" 2>/dev/null) \
        || PROJECT_INFO='{}'
    [ -z "$PROJECT_INFO" ] && PROJECT_INFO='{}'

    local COMPILER BUILD_SYS LOCI_TARGET
    COMPILER=$( "$JQ" -r '.compiler     // "unknown"' <<< "$PROJECT_INFO" 2>/dev/null || echo unknown)
    BUILD_SYS=$("$JQ" -r '.build_system // "unknown"' <<< "$PROJECT_INFO" 2>/dev/null || echo unknown)
    LOCI_TARGET=$("$JQ" -r '.loci_target // "unknown"' <<< "$PROJECT_INFO" 2>/dev/null || echo unknown)

    local HASH; HASH=$(_hash_cwd)
    local KEYED="${STATE_DIR}/project-context-${HASH}.json"

    "$JQ" --arg pwd "$(pwd)" '. + {project_root: $pwd}' <<< "$PROJECT_INFO" \
        > "$KEYED" 2>/dev/null || return 1

    (cd "$STATE_DIR" && ln -sf "$(basename "$KEYED")" project-context.json 2>/dev/null) \
        || cp "$KEYED" "${STATE_DIR}/project-context.json" 2>/dev/null

    # Context reminder — Claude Code injects SessionStart stdout into the
    # session, making this available to skills without re-running detection.
    printf '\nTarget: %s, Compiler: %s, Build: %s\nLOCI target: %s\n' \
        "$LOCI_TARGET" "$COMPILER" "$BUILD_SYS" "$LOCI_TARGET"
    printf 'Available: /exec-trace, /stack-depth, /memory-report, /control-flow\n'
    printf 'Auto-runs: loci-preflight (in /plan), loci-post-edit (after edits)\n'
}

# ── main ──────────────────────────────────────────────────────────────────────
_first_time_setup
_detect_and_write_context
exit 0

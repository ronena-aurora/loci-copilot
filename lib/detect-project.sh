#!/bin/bash
# Detect C++ project context: compiler, build system, binaries, ASM files.
# Outputs JSON for session initialization.

set -euo pipefail

CWD="${1:-.}"
IS_WINDOWS=false
[[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* ]] && IS_WINDOWS=true

# Windows: search well-known install directories for vendor compilers not on PATH.
# Returns the full path to the compiler binary, or fails.
_find_windows_compiler() {
  $IS_WINDOWS || return 1
  local name="$1"
  local candidates=()
  case "$name" in
    tiarmclang)
      candidates=(
        /c/ti/ticlang/bin/tiarmclang.exe
        /c/ti/ccs*/tools/compiler/ti-cgt-armllvm_*/bin/tiarmclang.exe
        /c/ti/ti-cgt-armllvm_*/bin/tiarmclang.exe
      ) ;;
    armcl)
      candidates=(
        /c/ti/ccs*/tools/compiler/ti-cgt-arm_*/bin/armcl.exe
        /c/ti/ti-cgt-arm_*/bin/armcl.exe
      ) ;;
    iccarm)
      candidates=(
        "/c/Program Files/IAR Systems/Embedded Workbench"*/arm/bin/iccarm.exe
        "/c/Program Files (x86)/IAR Systems/Embedded Workbench"*/arm/bin/iccarm.exe
      ) ;;
    armcc)
      candidates=(
        "/c/Keil_v5/ARM/ARMCC/bin/armcc.exe"
        "/c/Keil_v5/ARM/ARMCLANG/bin/armclang.exe"
        "/c/Program Files/Keil_v5/ARM/ARMCC/bin/armcc.exe"
      ) ;;
    arm-none-eabi-gcc)
      candidates=(
        /c/ti/gcc-arm-none-eabi/bin/arm-none-eabi-gcc.exe
        "/c/Program Files/GNU Arm Embedded Toolchain"*/bin/arm-none-eabi-gcc.exe
        "/c/Program Files (x86)/GNU Arm Embedded Toolchain"*/bin/arm-none-eabi-gcc.exe
      ) ;;
  esac
  for candidate in "${candidates[@]}"; do
    if [ -x "$candidate" ]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

# Detect C++ compiler (including vendor/embedded toolchains)
detect_compiler() {
  # Check standard compilers first
  command -v g++ >/dev/null 2>&1 && echo "g++" && return
  command -v clang++ >/dev/null 2>&1 && echo "clang++" && return
  # Vendor / embedded compilers
  command -v tiarmclang >/dev/null 2>&1 && echo "tiarmclang" && return
  command -v armcl >/dev/null 2>&1 && echo "armcl" && return
  command -v iccarm >/dev/null 2>&1 && echo "iccarm" && return
  command -v armcc >/dev/null 2>&1 && echo "armcc" && return
  command -v arm-none-eabi-gcc >/dev/null 2>&1 && echo "arm-none-eabi-gcc" && return
  command -v aarch64-linux-gnu-gcc >/dev/null 2>&1 && echo "aarch64-linux-gnu-gcc" && return
  command -v tricore-elf-gcc >/dev/null 2>&1 && echo "tricore-elf-gcc" && return
  # Windows: check well-known install directories
  if $IS_WINDOWS; then
    for comp in tiarmclang armcl iccarm armcc arm-none-eabi-gcc; do
      if _find_windows_compiler "$comp" >/dev/null 2>&1; then
        echo "$comp"
        return
      fi
    done
  fi
  echo "unknown"
}

# Detect build system (including vendor IDEs)
detect_build_system() {
  # Check root and one level of subdirectories
  [ -f "$CWD/CMakeLists.txt" ] && echo "cmake" && return
  [ -f "$CWD/Makefile" ] || [ -f "$CWD/makefile" ] && echo "make" && return
  [ -f "$CWD/meson.build" ] && echo "meson" && return
  [ -f "$CWD/BUILD" ] || [ -f "$CWD/WORKSPACE" ] && echo "bazel" && return
  [ -f "$CWD/conanfile.txt" ] || [ -f "$CWD/conanfile.py" ] && echo "conan" && return
  [ -f "$CWD/vcpkg.json" ] && echo "vcpkg" && return
  # Vendor IDE project files (root and subdirs)
  find "$CWD" -maxdepth 2 -name "*.projectspec" -print -quit 2>/dev/null | grep -q . && echo "ccs" && return
  find "$CWD" -maxdepth 2 -name "*.ccsproject" -print -quit 2>/dev/null | grep -q . && echo "ccs" && return
  find "$CWD" -maxdepth 2 -name ".cproject" -print -quit 2>/dev/null | grep -q . && echo "ccs" && return
  find "$CWD" -maxdepth 2 -name "*.ewp" -print -quit 2>/dev/null | grep -q . && echo "iar" && return
  find "$CWD" -maxdepth 2 -name "*.eww" -print -quit 2>/dev/null | grep -q . && echo "iar" && return
  find "$CWD" -maxdepth 2 -name "*.uvprojx" -print -quit 2>/dev/null | grep -q . && echo "keil" && return
  find "$CWD" -maxdepth 2 -name "*.uvproj" -print -quit 2>/dev/null | grep -q . && echo "keil" && return
  # Makefile in subdirectories
  find "$CWD" -maxdepth 2 -name "Makefile" -print -quit 2>/dev/null | grep -q . && echo "make" && return
  echo "direct"
}

# Find C++ source files
find_sources() {
  find "$CWD" -maxdepth 2 \( -name "*.cpp" -o -name "*.cxx" -o -name "*.cc" -o -name "*.c" -o -name "*.h" -o -name "*.hpp" \) 2>/dev/null | head -20 | jq -R . | jq -s .
}

# Find ELF/object files in common build directories
find_elf_files() {
  # Search broadly: all subdirectories up to 3 levels deep for ELF-type files
  local found=()
  while IFS= read -r f; do
    [ -n "$f" ] && found+=("$f")
  done < <(find "$CWD" -maxdepth 3 \( -name "*.elf" -o -name "*.out" -o -name "*.axf" \) -type f 2>/dev/null | head -30)

  # Also check .o files but only in common build directories (too many .o files otherwise)
  for d in build out Debug Release output bin obj artifacts .loci-build; do
    if [ -d "$CWD/$d" ]; then
      while IFS= read -r f; do
        [ -n "$f" ] && found+=("$f")
      done < <(find "$CWD/$d" -maxdepth 2 -name "*.o" -type f 2>/dev/null | head -10)
    fi
  done

  if [ ${#found[@]} -eq 0 ]; then
    echo '[]'
  else
    printf '%s\n' "${found[@]}" | sort -u | head -20 | jq -R . | jq -s .
  fi
}

# Find compiled binaries (executables in CWD root — legacy compat)
find_binaries() {
  local bins=()
  for f in "$CWD"/*; do
    if [ -f "$f" ] && [ -x "$f" ] && file "$f" 2>/dev/null | grep -qiE '(ELF|Mach-O|executable)'; then
      bins+=("$(basename "$f")")
    fi
  done
  if [ ${#bins[@]} -eq 0 ]; then
    echo '[]'
  else
    printf '%s\n' "${bins[@]}" | jq -R . | jq -s .
  fi
}

# Find assembly files
find_asm_files() {
  find "$CWD" -maxdepth 2 \( -name "*.asm" -o -name "*.s" -o -name "*.S" \) 2>/dev/null | head -20 | jq -R . | jq -s .
}

# Detect architecture from an ELF file using `file` command
arch_from_elf() {
  local elf_path="$1"
  local file_output
  file_output=$(file "$elf_path" 2>/dev/null) || return 1
  # Match architecture from file(1) output
  if echo "$file_output" | grep -qiE 'aarch64|ARM aarch64|ARM 64'; then
    echo "aarch64"
  elif echo "$file_output" | grep -qiE 'ARM,.*EABI|Thumb|Cortex|armv7|arm,'; then
    echo "arm"
  elif echo "$file_output" | grep -qiE 'TriCore|tricore'; then
    echo "tricore"
  elif echo "$file_output" | grep -qiE 'x86.64|x86-64|AMD64'; then
    echo "x86_64"
  elif echo "$file_output" | grep -qiE 'Intel 80386|i386|x86,'; then
    echo "i386"
  else
    return 1
  fi
}

# Detect architecture — prefer ELF analysis over uname
detect_architecture() {
  local elf_files="$1"
  # Try to detect from found ELF files first
  local elf_path
  elf_path=$(echo "$elf_files" | jq -r '.[0] // empty' 2>/dev/null)
  if [ -n "$elf_path" ] && [ -f "$elf_path" ]; then
    local arch
    arch=$(arch_from_elf "$elf_path")
    if [ -n "$arch" ]; then
      echo "$arch"
      return
    fi
  fi
  # Fallback: check executables in CWD
  for f in "$CWD"/*; do
    if [ -f "$f" ] && [ -x "$f" ] && file "$f" 2>/dev/null | grep -qiE '(ELF|Mach-O)'; then
      local arch
      arch=$(arch_from_elf "$f")
      if [ -n "$arch" ]; then
        echo "$arch"
        return
      fi
    fi
  done
  uname -m
}

# Detect available LOCI-compatible cross-compilers
detect_cross_compilers() {
  local compilers=()
  # GCC cross-compilers
  command -v aarch64-linux-gnu-g++ >/dev/null 2>&1 && compilers+=("aarch64")
  command -v aarch64-linux-gnu-gcc >/dev/null 2>&1 && compilers+=("aarch64")
  command -v arm-none-eabi-g++ >/dev/null 2>&1 && compilers+=("cortexm")
  command -v arm-none-eabi-gcc >/dev/null 2>&1 && compilers+=("cortexm")
  command -v tricore-elf-g++ >/dev/null 2>&1 && compilers+=("tricore")
  command -v tricore-elf-gcc >/dev/null 2>&1 && compilers+=("tricore")
  # Vendor compilers that target LOCI architectures
  command -v tiarmclang >/dev/null 2>&1 && compilers+=("cortexm")
  command -v armcl >/dev/null 2>&1 && compilers+=("cortexm")
  command -v iccarm >/dev/null 2>&1 && compilers+=("cortexm")
  command -v armcc >/dev/null 2>&1 && compilers+=("cortexm")
  # Windows: also check well-known install directories
  if $IS_WINDOWS; then
    _find_windows_compiler tiarmclang >/dev/null 2>&1 && compilers+=("cortexm")
    _find_windows_compiler armcl >/dev/null 2>&1 && compilers+=("cortexm")
    _find_windows_compiler iccarm >/dev/null 2>&1 && compilers+=("cortexm")
    _find_windows_compiler armcc >/dev/null 2>&1 && compilers+=("cortexm")
    _find_windows_compiler arm-none-eabi-gcc >/dev/null 2>&1 && compilers+=("cortexm")
  fi
  if [ ${#compilers[@]} -eq 0 ]; then
    echo '[]'
  else
    # Deduplicate
    printf '%s\n' "${compilers[@]}" | sort -u | jq -R . | jq -s .
  fi
}

# Map detected architecture to LOCI target (aarch64, cortexm, tricore) or null
resolve_loci_target() {
  local arch="$1"
  local cross_compilers="$2"
  local lower_arch
  lower_arch=$(echo "$arch" | tr '[:upper:]' '[:lower:]')
  case "$lower_arch" in
    aarch64|arm64)
      echo "aarch64" ;;
    arm|armv7*|cortex-m*|thumb)
      echo "cortexm" ;;
    tricore|tc3*|tc39*)
      echo "tricore" ;;
    *)
      # Host arch is not a LOCI target — check if any cross-compiler is available
      local first
      first=$(echo "$cross_compilers" | jq -r '.[0] // empty' 2>/dev/null)
      if [ -n "$first" ]; then
        echo "$first"
      else
        echo "null"
      fi
      ;;
  esac
}

# Detect compiler referenced in build configs (not necessarily in PATH)
detect_build_compiler() {
  local build_sys="$1"
  # Search build config files for compiler references
  local config_files=()
  case "$build_sys" in
    cmake) config_files=("$CWD/CMakeLists.txt" "$CWD/cmake"/*.cmake) ;;
    make) config_files=("$CWD/Makefile" "$CWD/makefile") ;;
    ccs) config_files=("$CWD"/*.projectspec "$CWD"/.cproject) ;;
    iar) config_files=("$CWD"/*.ewp) ;;
    keil) config_files=("$CWD"/*.uvprojx "$CWD"/*.uvproj) ;;
  esac

  for f in "${config_files[@]}"; do
    [ -f "$f" ] || continue
    # Look for compiler references in the file
    if grep -qiE 'tiarmclang|ti_arm_clang|TI_TOOLCHAIN' "$f" 2>/dev/null; then
      echo "tiarmclang" && return
    elif grep -qiE 'armcl|ti_arm_cgt|TI_CGT' "$f" 2>/dev/null; then
      echo "armcl" && return
    elif grep -qiE 'iccarm|IAR' "$f" 2>/dev/null; then
      echo "iccarm" && return
    elif grep -qiE 'armcc|ARMCC|armclang' "$f" 2>/dev/null; then
      echo "armcc" && return
    elif grep -qiE 'arm-none-eabi' "$f" 2>/dev/null; then
      echo "arm-none-eabi-gcc" && return
    elif grep -qiE 'aarch64-linux-gnu' "$f" 2>/dev/null; then
      echo "aarch64-linux-gnu-gcc" && return
    elif grep -qiE 'tricore-elf' "$f" 2>/dev/null; then
      echo "tricore-elf-gcc" && return
    fi
  done
  echo ""
}

COMPILER=$(detect_compiler)
BUILD_SYSTEM=$(detect_build_system)
SOURCES=$(find_sources)
ELF_FILES=$(find_elf_files)
BINARIES=$(find_binaries)
ASM_FILES=$(find_asm_files)
ARCH=$(detect_architecture "$ELF_FILES")
CROSS_COMPILERS=$(detect_cross_compilers)
LOCI_TARGET=$(resolve_loci_target "$ARCH" "$CROSS_COMPILERS")
BUILD_COMPILER=$(detect_build_compiler "$BUILD_SYSTEM")

# Resolve full path for compilers discovered via Windows search (not on PATH)
COMPILER_PATH=""
if $IS_WINDOWS && [ "$COMPILER" != "unknown" ] && ! command -v "$COMPILER" >/dev/null 2>&1; then
  COMPILER_PATH=$(_find_windows_compiler "$COMPILER" 2>/dev/null || true)
fi

# Determine LOCI compatibility
if [ "$LOCI_TARGET" != "null" ]; then
  LOCI_COMPATIBLE="true"
else
  LOCI_COMPATIBLE="false"
fi

jq -n \
  --arg compiler "$COMPILER" \
  --arg compiler_path "$COMPILER_PATH" \
  --arg build_compiler "$BUILD_COMPILER" \
  --arg build_system "$BUILD_SYSTEM" \
  --arg project_type "cpp" \
  --arg architecture "$ARCH" \
  --argjson source_files "$SOURCES" \
  --argjson binaries "$BINARIES" \
  --argjson elf_files "$ELF_FILES" \
  --argjson asm_files "$ASM_FILES" \
  --argjson cross_compilers "$CROSS_COMPILERS" \
  --argjson loci_compatible "$LOCI_COMPATIBLE" \
  --arg loci_target "$LOCI_TARGET" \
  --arg detected_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  '{
    language_stack: ["cpp"],
    compiler: $compiler,
    compiler_path: (if $compiler_path == "" then null else $compiler_path end),
    build_compiler: (if $build_compiler == "" then null else $build_compiler end),
    build_system: $build_system,
    project_type: $project_type,
    architecture: $architecture,
    source_files: $source_files,
    binaries: $binaries,
    elf_files: $elf_files,
    asm_files: $asm_files,
    cross_compilers: $cross_compilers,
    loci_compatible: $loci_compatible,
    loci_target: (if $loci_target == "null" then null else $loci_target end),
    detected_at: $detected_at
  }'

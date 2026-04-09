# loci

DEVDEV _____
Execution-aware analysis for C/C++/Rust — hardware-grounded timing, energy, stack depth, memory, and security from compiled binaries. Real silicon traces, not simulated.

## Install

```
/plugin marketplace add auroralabs-loci/loci-claude
/plugin install loci@loci
```

## Quick Start

After installing, try these in any C/C++/Rust project with compiled binaries:

1. **Timing & energy** — ask: *"What's the execution cost of main()?"*
2. **Memory budget** — ask: *"How much ROM/RAM does my build use?"*
3. **Stack safety** — ask: *"Is my stack safe for TaskMain?"*

LOCI also runs automatically:
- **loci-preflight** fires during `/plan` mode when you describe new logic
- **loci-post-edit** fires after every edit to C/C++/Rust source files

## Skills

| Skill | Trigger | What it does |
|-------|---------|--------------|
| **loci-preflight** | Auto in `/plan` mode | Execution-aware analysis (timing, energy, CFG) on callees before you write code |
| **loci-post-edit** | Auto after edits | Compares pre/post compiled artifacts — reports timing %, energy delta, control-flow changes |
| **exec-trace** | User-invoked | Function-level execution timing and energy from real hardware traces |
| **stack-depth** | User-invoked | Worst-case stack depth via call-graph traversal, per-function frame sizes |
| **memory-report** | User-invoked | ROM/RAM section breakdown, top consumers, region budget usage |
| **control-flow** | User-invoked | Annotated control-flow graphs optimized for LLM analysis |

## Hooks

| Hook | Trigger | Action |
|------|---------|--------|
| `SessionStart` | startup | project detection, venv setup, context injection |
| `PreToolUse` | Edit, Write, MultiEdit | call-graph safety check, `.o` snapshot for delta analysis |

## LOCI MCP

Connects to `https://dev.local.mcp.loci-dev.net/mcp/v1` for hardware-grounded timing and energy predictions from real silicon traces.

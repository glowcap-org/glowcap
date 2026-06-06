---
description: "Zig pancake execution model — gates, generated state, and git posture."
alwaysApply: true
---

# pancake — Execution Model

## Gates

Run before calling code work complete:

```sh
zig build check
```

`zig build check` runs the Zig-hermetic gate: architecture checks, meta
scaffolding checks, correctness tests, public examples, protocol/Goblins oracle
checks, and benchmark smoke checks. Cross-language C ABI dogfood runs as sibling
steps because it requires non-Zig runtimes on PATH. Use focused steps while
iterating:

```sh
zig build test
zig build meta-check
zig build oracle-check
zig build rust-dogfood
zig build bindings
zig build examples
zig build bench-frame-view
zig build bench-codec
```

## Devcontainer

The committed `.devcontainer/` is the canonical ready-to-build environment.
Versions and paths live in [`.devcontainer/pins.sh`](../.devcontainer/pins.sh);
per-arch checksums in [`checksums.sh`](../.devcontainer/checksums.sh).
[`check-env-sync.sh`](../.devcontainer/check-env-sync.sh) keeps `Dockerfile` and
`devcontainer.json` aligned with `pins.sh`. Install scripts are host orchestration
only — the project gate remains `zig build check`. After container open:
`bash .devcontainer/post-create.sh`, then `zig build check`.
See [`.devcontainer/README.md`](../.devcontainer/README.md). Serena MCP is
client-started (stdio); see [serena-mcp](serena-mcp.md).

Put first-class project commands in `build.zig`; devcontainer scripts handle image
build, cache ownership, and toolchain pin checks only.

## Generated State

Generated state is ignored and must not be committed:

- `.zig-cache/`
- `zig-out/`
- `.serena/cache/`
- `.serena/logs/`
- `.serena/memories/` unless a maintainer explicitly asks to share a memory
- `bindings/rust/target/`
- `bindings/rust/Cargo.lock`

If generated cache appears in status, fix `.gitignore` rather than relying on
manual cleanup.

## Git Posture

Agents do not mutate git history. Read-only git commands are fine: `status`,
`diff`, `log`, `show`, `blame`, `branch`, `rev-parse`, `ls-files`.

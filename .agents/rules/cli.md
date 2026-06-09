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
checks, and benchmark smoke checks. Cross-language C ABI dogfood and the live
Goblins interop run as sibling steps because they require non-Zig runtimes on
PATH. Use focused steps while iterating:

```sh
zig build test
zig build meta-check
zig build oracle-check
zig build rust-dogfood
zig build bindings
zig build goblins-interop   # live OCapN conversation vs a real Goblins vat, both directions (needs racket + goblins)
zig build deno-goblins-interop   # live keyed conversation: Deno binding vs a real Goblins vat over the C ABI (needs deno + racket + goblins)
zig build python-goblins-interop # live keyed conversation: Python binding vs a real Goblins vat (needs python3 + racket + goblins)
zig build rust-goblins-interop   # live keyed conversation: Rust binding vs a real Goblins vat (needs cargo + racket + goblins)
zig build racket-goblins-interop # live keyed conversation: Racket binding vs a real Goblins vat (needs racket + goblins)
zig build goblins-handoff   # live three-party handoff vs Goblins, pancake as recipient (needs racket + goblins)
zig build ocapn-conformance # run the upstream OCapN test suite against a pancake peer (needs uv + the ocapn-conformance submodule)
zig build rooms             # cross-language rooms chat: Zig/Rust/Python/Racket/Deno in one room (needs deno; joins python3/racket/cargo clients when present)
zig build tasks             # cross-language tasks board: Zig/Rust/Python/Deno on one board (needs deno; joins python3/cargo clients when present)
zig build tools             # cross-language capability showcase: delegation/attenuation/revocation for AI agent harnesses (needs deno; joins python3 agent when present)
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

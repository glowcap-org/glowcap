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

A gate passes by its exit code, not by its output: piping through `tail` or
`grep` reports the pipe's status and turns a failing build into a false green.
Run `zig build` from the repository root: run from a subdirectory it drops
`zig-out/` and `.zig-cache/` debris where it stands and resolves relative
manifest paths wrong.

`zig build check` runs the Zig-hermetic gate: architecture checks, meta
scaffolding checks, correctness tests, public examples, protocol/Goblins oracle
checks, the accountability application and its three-party attribution test,
and benchmark smoke checks. Cross-language C ABI dogfood and the live
Goblins interop run as sibling steps because they require non-Zig runtimes on
PATH. Use focused steps while iterating:

```sh
zig build test
zig build test -Dtest-filter=substring   # only tests whose names match
zig build arch-check
zig build meta-check
zig build docs              # generate the Zig API reference (autodoc) under zig-out/docs/
zig build site              # build the documentation site (Zine + autodoc) under zig-out/site/
zig build docs-serve        # serve the documentation site locally at http://127.0.0.1:1990/pancake/
zig build oracle-check
zig build cross-check        # compile-only: full library for macOS (kqueue) + sans-io core for wasm32 — part of check
zig build rust-dogfood      # Rust C ABI dogfood against libpancake (needs cargo)
zig build deno-dogfood      # Deno C ABI dogfood against libpancake (needs deno)
zig build python-dogfood    # Python C ABI dogfood against libpancake (needs python3)
zig build racket-dogfood    # Racket C ABI dogfood against libpancake (needs racket)
zig build bindings          # all four dogfoods together
zig build goblins-interop   # live OCapN conversation vs a real Goblins vat, both directions (needs racket + goblins)
zig build deno-goblins-interop   # live keyed conversation: Deno binding vs a real Goblins vat over the C ABI (needs deno + racket + goblins)
zig build python-goblins-interop # live keyed conversation: Python binding vs a real Goblins vat (needs python3 + racket + goblins)
zig build rust-goblins-interop   # live keyed conversation: Rust binding vs a real Goblins vat (needs cargo + racket + goblins)
zig build racket-goblins-interop # live keyed conversation: Racket binding vs a real Goblins vat (needs racket + goblins)
zig build goblins-handoff   # live three-party handoff vs Goblins, pancake as recipient (needs racket + goblins)
zig build iroh-lib          # build the iroh netlayer sidecar staticlib in transports/iroh (needs cargo)
zig build iroh-interop      # live encrypted OCapN conversation: two pancake peers over real iroh endpoints (needs cargo)
zig build iroh-abi          # build libpancake_iroh — the iroh transport's public C ABI superset (needs cargo)
zig build fixture-gen-check # regenerate the Syrup fixture corpus via the upstream Racket Syrup encoder and diff against the committed bytes (needs racket + syrup)
zig build ocapn-conformance # run the upstream OCapN test suite against a pancake peer (needs uv + the ocapn-conformance submodule)
zig build demo-rooms             # cross-language rooms chat: Zig/Rust/Python/Racket/Deno in one room (needs deno; joins python3/racket/cargo clients when present)
zig build demo-rooms-iroh        # the rooms chat over iroh's encrypted QUIC: an iroh-enabled Zig client + cross-language clients through the iroh C ABI (needs cargo + deno)
zig build demo-tasks             # cross-language tasks board: Zig/Rust/Python/Racket/Deno on one board (needs deno; joins python3/racket/cargo clients when present)
zig build demo-tools        # cross-language capability showcase: delegation/attenuation/revocation for AI agent harnesses (needs deno; joins python3/racket/cargo agents when present)
zig build accountability             # accountability application on pancake's own runtime over a real loopback TCP socket
zig build accountability-three-party # three-party accountability attribution across the handoff seam (in-memory, pure Zig)
zig build demo-accountability        # cross-language accountability demo: Zig host + Deno/Python callers (needs deno)
zig build examples
zig build gen-header        # regenerate include/pancake.h from src/c_abi
zig build gen-header-check  # verify include/pancake.h matches src/c_abi (fails if stale) — part of check
zig build gen-header-iroh        # regenerate include/pancake_iroh.h from src/c_abi/iroh.zig
zig build gen-header-iroh-check  # verify include/pancake_iroh.h matches src/c_abi/iroh.zig (fails if stale) — part of check
zig build bench-frame-view
zig build bench-codec
zig build bench-peer-scaling # measure per-connection memory footprint and extrapolate to 500k connections; writes a report under zig-out/bench-reports/
zig build bench-goblins      # cross-implementation benchmark: pancake's Racket binding vs Spritely Goblins, one shared app (needs racket + goblins); `-- --smoke`/`--suite=<name>` forwarded, writes a report under zig-out/bench-reports/
```

`-Dport=N` pins the listening TCP port for the demo and live interop steps
(default: ephemeral for demos, each step's documented fixed port for interop;
`goblins-handoff` runs two listeners and takes N and N+1). `-Dattach=true`
(demo steps only, requires `-Dport`) joins an already-running server on that
port instead of spawning one; `demo-accountability` rejects it because each
caller needs a fresh host.

## Devcontainer

The committed `.devcontainer/` is the canonical ready-to-build environment.
Versions and paths live in [`.devcontainer/pins.sh`](../../.devcontainer/pins.sh);
per-arch checksums in [`checksums.sh`](../../.devcontainer/checksums.sh).
[`check-env-sync.sh`](../../.devcontainer/check-env-sync.sh) keeps `Dockerfile` and
`devcontainer.json` aligned with `pins.sh`. Install scripts are host orchestration
only — the project gate remains `zig build check`. After container open:
`bash .devcontainer/post-create.sh`, then `zig build check`.
See [`.devcontainer/README.md`](../../.devcontainer/README.md). Serena MCP is
client-started (stdio); see [serena-mcp](serena-mcp.md).

Put first-class project commands in `build.zig`; devcontainer scripts handle image
build, cache ownership, and toolchain pin checks only.

## Generated State

Generated state is ignored and must not be committed:

- `.zig-cache/`
- `zig-out/`
- `zig-pkg/` (Zig's extracted-package dir; appears at `site/zig-pkg/` for the site sub-build)
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

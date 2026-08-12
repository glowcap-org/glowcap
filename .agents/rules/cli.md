---
description: "Zig pancake execution model, gates, generated state, and git posture."
alwaysApply: true
---

# pancake — Execution Model

## Gates

Run before calling code work complete:

```sh
zig build check
```

**A gate passes by its exit code, not by its output**, in both directions.
Piping through `tail` or `grep` reports the pipe's status and turns a failing
build into a false green. Conversely, the build runner echoes a passing step's
captured stderr under a `failed command:` label, so error-shaped output in a
green log is not a failure verdict.

`check` needs no network, no submodules, and no live peer, and is the step to run
while iterating; its cost is that a green `check` proves only that pancake agrees
with pancake. It is not Zig-only: Cargo links the CLI tests' iroh sidecar, and
two Bash harnesses make `tar` part of the hard floor. Deno and Python extend
those harnesses when present and report explicit skips otherwise. **Run `check`
in the devcontainer**, where the complete declared toolchain is pinned.
`check_runtimes` in `build.zig` names every program visible in the build graph
and the scripts allowed to hide host-tool calls, so raising the hard floor is a
reviewed edit rather than a silent one.

`check-external` is the other half, every check whose authority is outside
pancake, and `ci/gates.sh` runs the same set on every push to the mirror. Run it
before believing a protocol claim. Cross-language dogfood, live Goblins interop,
and the Rust/TypeScript formatting check stay siblings rather than members,
because each needs an outside authority or a whole language runtime of its own.

### A hang is usually contention, not your change

Run `zig build` from the repository root: from a subdirectory it drops
`zig-out/` and `.zig-cache/` debris where it stands and resolves relative
manifest paths wrong. Test runs are exclusive, because the suite and the interop
steps bind real loopback ports. Two concurrent runs (a second agent, an editor's
build-on-save, a stale run a crashed session left behind) wedge each other's
test binaries in silent socket waits that look like hangs. Three faces of the
same problem, each with its own sweep:

- A "hung" gate: sweep for orphaned `.zig-cache/o/*/test` processes from a dead
  session, then run the gate alone.
- A `check` that fails compiling executables which build fine alone: a live
  rival builder is racing the cache. Find it with `ps aux | grep 'zig build'`
  before touching code.
- A step that fails with no printed assertion while its binary passes
  standalone, its cache hash changing on every retry: same rival. Only an
  *actively compiling* one collides, so a parked `--watch` runner at 0% CPU is
  innocent. Wait out live compiles and link stragglers, then re-run.

A *failed* `ocapn-conformance` run can leave its peer behind on the fixed port
and the next run inherits it, showing up as one unrelated `ConnectionResetError`
where the suite expected a timeout. Re-run alone before believing a conformance
failure that names a test your change does not touch.

Wrap CapTP and socket work in `timeout N` (tens of seconds) rather than waiting
forever: a silent hang is almost always an unbounded wait, not a slow test. See
Product CapTP waits below.

### Focused steps

Every step, grouped by what it proves, lives in
[`docs/build-steps.md`](../../docs/build-steps.md), and that page is the one
place a new step gets documented. The steps worth remembering:

```sh
zig build check              # the gate; run before calling code work complete
zig build check-external     # the external-authority half (needs uv + racket + goblins)
zig build test
zig build test -Dtest-filter=substring   # only tests whose names match
zig build arch-check
zig build meta-check
zig build oracle-check
zig build fmt                # format Zig sources in place
zig build cli-test           # hermetic pancake CLI goldens
zig build examples
zig build fuzz               # mutation-fuzz every hostile-input target
zig build pancake            # run the CapTP CLI; pass `-- <command> …`
```

## Devcontainer

The committed `.devcontainer/` is the canonical ready-to-build environment, and
[`.devcontainer/pins.sh`](../../.devcontainer/pins.sh) owns every version and
path ([`checksums.sh`](../../.devcontainer/checksums.sh) holds the per-arch
checksums, and [`check-env-sync.sh`](../../.devcontainer/check-env-sync.sh) keeps
`Dockerfile` and `devcontainer.json` aligned with it). After container open, run
`bash .devcontainer/post-create.sh`, then `zig build check`; the notes are in
[`.devcontainer/README.md`](../../.devcontainer/README.md). Serena MCP is
client-started over stdio, see [serena-mcp](serena-mcp.md).

Put first-class project commands in `build.zig`. Devcontainer scripts handle
image build, cache ownership, and toolchain pin checks only.

The browser proofs need no setup, because the image installs the pinned
Playwright Chromium into `PLAYWRIGHT_BROWSERS_PATH`. The driving library must be
that same version, so `meta-check` holds every Deno scope's `playwright` import
to `PLAYWRIGHT_VERSION` in `pins.sh` and refuses an inline
`npm:playwright@<version>` specifier, which is a second pin that will drift. A
browser step fails through `tools/check/playwright-preflight.sh`, which tells a
missing browser apart from a stale one: raising the pin renames the build number
Playwright looks for, so every browser already in a running container becomes
invisible to it and the remedy is a rebuild. Do not answer either with a
hand-run `npx playwright install`, which lands elsewhere.

## Generated State

Generated state is ignored and must not be committed:

- `.zig-cache/`
- `zig-out/`
- `zig-pkg/` (Zig's extracted-package dir; appears at `site/zig-pkg/` for the
  site sub-build)
- `.serena/cache/`
- `.serena/logs/`
- `.serena/memories/` unless a maintainer explicitly asks to share a memory
- `bindings/rust/target/`
- `bindings/rust/Cargo.lock`

If generated cache appears in status, fix `.gitignore` rather than relying on
manual cleanup.

The committed FFI tiers are generated too, and are never hand-edited. Each says
so in its own first lines, a GENERATED header naming the `gen-*` step that
writes it. Trust that header rather than any list, because a directory mixes
generated and hand-written files freely: `bindings/ts/stack/internal/ffi/` holds
both, as does every binding tree and `include/pancake_*.h`.

Changing a C signature means editing the Zig export, its row in that archive's
`symbols.zig` inventory, and the header prose in _both_ the export's doc comment
and `tools/gen/header/*.zig`, then running that archive's `gen-*` step. The
paired `gen-*-check` steps ride `check`, so a hand-edit is caught, but it is
caught as staleness rather than as the signature change it was meant to be.

## Git Posture

Agents do not mutate git history. Read-only git commands are fine: `status`,
`diff`, `log`, `show`, `blame`, `branch`, `rev-parse`, `ls-files`.

`git checkout -- <path>` and `git restore` are working-tree writes, not reads:
on a tree carrying uncommitted work they destroy that work. To undo a probe
edit, restore from a copy saved beside the scratchpad before probing, never
from git.

A commit made when directed stages explicit paths, never `-a`/`-u`/`add .`:
other sessions work this tree concurrently, and a sweep commit that picks up
half of another session's in-flight edits ships a HEAD that does not compile.
Read `git status` immediately before staging and claim only your own files.

## Live CapTP (product CLI)

When CapTP must happen live in the session — call/fetch/tell a peer, host a
temporary listener, open a REPL, or script `--json` — load the
[pancake-cli skill](../skills/pancake-cli/SKILL.md): `zig build`, put
`zig-out/bin` on `PATH`, then use `pancake`. CapTP through the agent host's MCP
tools uses the project server (`.cursor/mcp.json` / `.mcp.json` →
`./pancake mcp`); load [pancake-mcp](../skills/pancake-mcp/SKILL.md).
Do not invent a Zig harness or binding stub for a shell-shaped CapTP act.
Room presence wake-loops stay in [rooms-peer](../skills/rooms-peer/SKILL.md).
Human walkthrough: [`docs/cli.md`](../../docs/cli.md). Hermetic goldens:
`zig build cli-test`.

## Product CapTP waits (cli/)

`SessionOptions.handshake` and `.settle` are `driver.Budget` and have no
default, so omitting one is a compile error naming both fields. What still
compiles is `.unbounded`, which is right for an in-process pair and a hang
anywhere a partner can go silent: it parks the process and any golden that
dials. (A `.ms` of zero or less is not the hang: it has already expired and
times out immediately, in every build mode.) Product paths use
`cli/ocapn.sessionOpts()` (finite ms), and tests that dial CapTP name a finite
budget too. `meta-check` refuses `.unbounded` under `cli/` and under
`examples/zig/**`, where it is worse than a hang because a reader copies it;
`test/cli/session_cases.zig` pins the silent-partner timeout. The
buffer-explicit constructors take the handshake budget positionally and are
checked for a bounded last argument. Map `HandshakeTimedOut` / `WaitTimedOut`
to exit code `timeout`.

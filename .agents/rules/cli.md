---
description: "Zig glowcap execution model, gates, generated state, and git posture."
alwaysApply: true
---

# glowcap — Execution Model

## Gates

Choose evidence by the boundary that changed:

```sh
zig build source-check         # docs, plans, static scaffolding, cross-file contracts
zig build check                # in-process Zig, static, generated, compile, and performance checks
zig build runtime-check        # deterministic child processes and language workspaces
zig build infrastructure-check # executable devcontainer and worktree behavior
zig build check-external       # outside protocol authority and shipped browser journeys
```

**A gate passes by its exit code, not by its output**, in both directions.
Piping through `tail` or `grep` reports the pipe's status and turns a failing
build into a false green. Conversely, the build runner echoes a passing step's
captured stderr under a `failed command:` label, so error-shaped output in a
green log is not a failure verdict.

`check` needs no network, no submodules, and no live peer. It keeps evidence
that runs in a self-contained Zig process or has no service lifecycle: Zig unit
and scenario tests, generated-state checks, compile-only consumers, and
performance budgets. `runtime-check` owns suites with live process or socket
lifecycles and language workspaces with shared output. Its side-effecting
commands take the build runner's execution lock, so they cannot race ports,
processes, or shared output directories.
Run both in the devcontainer when both boundaries changed.

`check` is not Zig-only: Python enforces deterministic deadlines and
compile-checks its benchmark client, Cargo checks compile-only consumers,
`raco` compiles Racket clients, Bash harnesses make `tar` part of the hard
floor, and Deno type-checks TypeScript surfaces. `runtime-check` also reaches
POSIX-shell installation recipes that copy artifacts and stamp Git revisions.
**Run checks in the
devcontainer**, where the complete declared toolchain is pinned.
`in_tree_runtimes` in `tools/build/toolchain.zig` names every program visible in the
build graph and the interpreter scripts or modules allowed to hide host-tool
calls, so raising the hard floor is a reviewed edit rather than a silent one.
`toolchain-check` reads that table both ways, so a declared program that is not
installed here is named with its reason before the gate spends a compile on it.
Its sibling `in_tree_capabilities` covers what the graph cannot see, a toolchain
target that is state inside a program rather than an argument to it, by
declaring the command that reports the capability and the text that report must
contain. Both failures usually mean the container is older than the image layer
that installs the thing, and the report says so: rebuild rather than
hand-install, because hand-installing answers one report and leaves the next
layer of the same rebuild to find you.

`infrastructure-check` black-boxes the devcontainer and worktree integration
tools in temporary repositories. It stays separate from `source-check`, whose
job is static source, documentation, generated mirrors, and scaffolding truth.
A plan-only documentation edit therefore runs `source-check`, not the product
or infrastructure gates.

`check-external` holds evidence whose authority is outside glowcap, and
`ci/gates.sh` runs the recurring set on every push to the mirror. Run it before
believing a protocol claim. Cross-language dogfood and live Goblins interop
stay siblings when they carry narrower ownership than the aggregate.

### Build ownership and unusual failures

Run `zig build` from the repository root. A run from a subdirectory creates
output there and resolves relative manifests against the wrong directory.

Agent sessions should enter the devcontainer through
`.agents/skills/work/bin/glowcap-dev`. For finite `zig build` commands it adds
the per-test timeout and acquires one build lease for the worktree. On the host
it enters that worktree's running container. Inside the glowcap image it stays
local and changes to the repository root. A contender prints the owning PID,
working directory, and command, then exits 75 instead of racing `zig-out`, the
Zig cache, Cargo's target directory, or fixed loopback ports. Set
`GLOWCAP_BUILD_LEASE_TIMEOUT` only when waiting is the intended work.
Long-running service steps such as `docs-serve`, `rooms-dev`, and
`ocapnviz-dev` do not take the lease. Direct host builds remain supported when
the host provides the declared toolchain.

Inside `runtime-check`, side-effecting process commands inherit stdio and use
the build runner's global execution lock. The runtime aggregate changes their
execution posture, not their dependencies. A focused check and a product
launch cannot acquire unrelated runtime families through a shared compiler
step. CI invokes top-level gates in sequence and gives each one an
outer containment deadline. Zig unit tests use the build runner's
per-active-test deadline, so aggregate suite growth cannot make the last test
look slow.

If the lease refuses the build or an explicit wait expires, inspect the current
build and its children before changing code. If no owner is alive but a child
still holds a port, identify and stop that exact process, then rerun the focused
step. A conformance failure on an unrelated module is not evidence of protocol
drift until the focused module reproduces with no inherited peer.

Wrap CapTP and socket work in `timeout N` (tens of seconds) rather than waiting
forever: a silent hang is almost always an unbounded wait, not a slow test. See
Product CapTP waits below.

### Focused steps

Every step, grouped by what it proves, lives in
[`docs/build-steps.md`](../../docs/build-steps.md), and that page is the one
place a new step gets documented. The steps worth remembering:

```sh
zig build check              # in-process Zig, static, generated, compile, and performance evidence
zig build runtime-check      # process and language-workspace evidence
zig build infrastructure-check # devcontainer and worktree behavior
zig build check-external     # the external-authority half (needs uv + racket + goblins)
zig build test
zig build test -Dtest-filter=substring   # only tests whose names match
zig build arch-check
zig build source-check
zig build oracle-check
zig build fmt                # format Zig sources in place
zig build cli-test           # hermetic glowcap CLI goldens
zig build examples
zig build fuzz               # mutation-fuzz every untrusted-input target
zig build glowcap            # run the CapTP CLI; pass `-- <command> …`
```

## Devcontainer

The committed `.devcontainer/` is the canonical ready-to-build environment, and
[`.devcontainer/pins.sh`](../../.devcontainer/pins.sh) owns every version and
path ([`checksums.sh`](../../.devcontainer/checksums.sh) holds the per-arch
checksums, and [`test/env-sync.sh`](../../.devcontainer/test/env-sync.sh) holds
every file that restates a pin or a path to it). Dependency updates run
through [`bin/update-pins.sh`](../../.devcontainer/bin/update-pins.sh) (`check`, then
`bump <dep>` / `bump --safe`), which fetches versions and checksums from each
tool's release channel and validates the staged edit; do not hand-edit a pin
against upstream. After container open, `hooks/post-create.sh` verifies the
environment automatically; then run `zig build check`. The notes are in
[`.devcontainer/README.md`](../../.devcontainer/README.md). Serena MCP is
client-started over stdio, see [serena-mcp](serena-mcp.md).

Put first-class project commands in `build.zig`. Devcontainer scripts own
development-environment selection, image build, cache ownership, and toolchain pins.

The browser proofs need no setup, because the image installs the pinned
Playwright Chromium into `PLAYWRIGHT_BROWSERS_PATH`. The driving library must be
that same version, so `source-check` holds every Deno scope's `playwright` import
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
- `zig-pkg/` (Zig's extracted-package dir; appears at `site/zig-pkg/` and
  `tools/consumer/zig-pkg/` when `ZIG_LOCAL_PKG_DIR` is unset)
- `.serena/cache/`
- `.serena/logs/`
- `.serena/memories/` unless a maintainer explicitly asks to share a memory
- `bindings/rust/target/`
- `bindings/rust/Cargo.lock`

In the devcontainer, Zig's local cache and extracted packages live in the
per-worktree `glowcap-dev-<worktree>-zig-work` Docker volume
(`ZIG_LOCAL_CACHE_DIR`, `ZIG_LOCAL_PKG_DIR`), not in the checkout or a host
bind. `zig-out/` stays at the worktree root: it is the install prefix.

If generated cache appears in status, fix `.gitignore` rather than relying on
manual cleanup.

The committed FFI tiers are generated too, and are never hand-edited. Each says
so in its own first lines, a GENERATED header naming the `gen-*` step that
writes it. Trust that header rather than any list, because a directory mixes
generated and hand-written files freely: `bindings/ts/runtime/internal/ffi/` holds
both, as does every binding tree and `include/glowcap_*.h`.

Changing a C signature means editing the Zig export, its row in that archive's
`symbols.zig` inventory, and the header prose in _both_ the export's doc comment
and `tools/gen/header/*.zig`, then running that archive's `gen-*` step. The
paired `gen-*-check` steps ride `check`, so a hand-edit is caught, but it is
caught as staleness rather than as the signature change it was meant to be.

`gen-mark` is the one generator whose authority is not Zig and whose check does
not ride `check`: the mark's shape lives in a WebGPU shader, so both steps run
the pinned browser and sit beside `check` like every other browser proof. What
rides `check` is `source-check`, which holds the committed mark files to one
geometry without rendering anything.

## Git Posture

Each agent session owns one linked worktree, not the clone. All worktrees share
the clone's refs, so moving a ref can affect another session; their indexes and
working files remain separate. The worktree/container designator and branch
name are independent facts: read the branch with `git branch --show-current`,
never infer it from a directory, container, another worktree, or an example in
this rule. Git writes stay on that branch. Read-only git commands are fine:
`status`, `diff`, `log`, `show`, `blame`, `branch`, `rev-parse`, `ls-files`.

`git worktree add`, `remove`, and `prune` write the clone's worktree registry
and are never run from a session. The registered paths resolve only on the
host, so a `prune` from a container deletes the registry and submodule stores
of every linked worktree it cannot see, its own included. Worktrees are
created `--lock`ed so a prune skips them; leave the lock alone.

`git checkout -- <path>` and `git restore` are working-tree writes, not reads:
on a tree carrying uncommitted work they destroy that work. To undo a probe
edit, restore from a copy saved beside the scratchpad before probing, never
from git.

A commit made when directed stages explicit paths, never `-a`/`-u`/`add .`:
other sessions work this tree concurrently, and a sweep commit that picks up
half of another session's in-flight edits ships a HEAD that does not compile.
Read `git status` immediately before staging and claim only your own files.

Stay on that current branch and commit there. Never check out `main`, `dev`, or
another worktree's branch: doing so mixes their index into yours. `dev` is the
sole shared integration ref. `main` is never moved by a worktree agent.

Commit on the worktree branch, rebase that branch onto `main`, then onto `dev`,
then fast-forward it into `dev`. At the start of a work stint, and before
diagnosing a broad gate on an older branch, synchronize a clean worktree without
publishing it:

```sh
.agents/skills/work/bin/glowcap-integrate --sync
```

This rebases the current branch onto observed `main` and `dev`, but never moves
either shared ref. It is the supported way to consume other worktrees'
integrated repairs before adding or judging new work.

After a clean, evidenced commit, run the repository-owned integration command:

```sh
.agents/skills/work/bin/glowcap-integrate
```

Both modes refuse detached heads, `main`/`dev`, and a dirty tree. Publication
rebases the current branch onto observed `main` and `dev`, then compare-and-swaps
`dev` to `HEAD` (a fast-forward merge; agents never check out `dev`). The
expected-old check is load-bearing: an ancestor check followed by an
unconditional `update-ref` has a race that can erase another agent's tip. The
black-box contract rides `zig build infrastructure-check`.

Commit in small, evidenced steps on the worktree. `dev` takes one commit per
change: one commit lands as written, and several need `-m "<subject>"` to land
as one squash listing their subjects.

## Live CapTP (product CLI)

When CapTP must happen live in the session — call/fetch/tell a peer, host a
temporary listener, open a REPL, or script `--json` — load the
[glowcap-cli skill](../skills/glowcap-cli/SKILL.md): `zig build`, put
`zig-out/bin` on `PATH`, then use `glowcap`. CapTP through the agent host's MCP
tools uses the project server (`.cursor/mcp.json` / `.mcp.json` →
`./glowcap mcp`); load [glowcap-mcp](../skills/glowcap-mcp/SKILL.md).
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
budget too. `source-check` refuses `.unbounded` under `cli/` and under
`examples/zig/**`, where it is worse than a hang because a reader copies it;
`test/cli/session_cases.zig` pins the silent-partner timeout. The
buffer-explicit constructors take the handshake budget positionally and are
checked for a bounded last argument. Map `HandshakeTimedOut` / `WaitTimedOut`
to exit code `timeout`.

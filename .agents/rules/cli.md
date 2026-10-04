---
description: "Zig glowcap execution model: gates, the devcontainer front, generated state, and git posture."
alwaysApply: true
---

# glowcap — Execution Model

## Gates

Run every gate from the repository root through the front, as in
`.agents/skills/work/bin/glowcap-dev zig build check`. The front enters this worktree's devcontainer (the
pinned toolchain), applies the per-test deadline, and holds one build lease per
worktree. A contender exits 75 naming the owner; inspect that owner before
changing code. Set `GLOWCAP_BUILD_LEASE_TIMEOUT` only when waiting is the work.

Choose evidence by the boundary that changed:

```sh
zig build source-check         # docs, scaffolding, generated mirrors, cross-file contracts
zig build check                # in-process Zig, static, generated, compile, and performance evidence
zig build runtime-check        # child processes, sockets, and language workspaces
zig build infrastructure-check # devcontainer, worktree, and hook behavior
zig build check-external       # outside protocol authority and shipped browser journeys
```

- A gate passes by its exit code. Never pipe a gate through `tail`/`grep` and
  read the pipe's status; a green log can still echo `failed command:` stderr.
- Iterate on the narrowest step (`zig build test -Dtest-filter=<name>`), then
  combine compatible final gates in one invocation. Record command, exit
  status, scope, and environment limits. Evidence stays valid until its inputs
  change; do not rerun a broad suite because a review phase started.
- A failure gets a focused reproduction before another aggregate run (the
  [debugging skill](../skills/debugging/SKILL.md)).
- Bound CapTP and socket work with a deadline of tens of seconds. A silent hang
  is an unbounded wait, not a slow test.
- [`docs/build-steps.md`](../../docs/build-steps.md) is the one place every
  step is documented.

## Devcontainer

The committed `.devcontainer/` is the environment of record.
[`pins.sh`](../../.devcontainer/pins.sh) and
[`checksums.sh`](../../.devcontainer/checksums.sh) own tool versions; move them
with `.devcontainer/bin/update-pins.sh`, and never weaken a check to accept an
update. A toolchain-check or Playwright-preflight failure means the container is
older than the image: rebuild it, never hand-install. Zig's cache lives in the
per-worktree `glowcap-dev-<worktree>-zig-work` volume; `zig-out/` stays at the
worktree root. [The environment notes](../../.devcontainer/README.md) own every
procedure.

## Generated State

Never committed; `source-check` holds each against `.gitignore` and the index:

- `.zig-cache/`
- `zig-out/`
- `zig-pkg/`
- `.serena/cache/`
- `.serena/logs/`
- `.serena/memories/`
- `bindings/rust/target/`
- `bindings/rust/Cargo.lock`

Committed FFI tiers and headers are generated; their first lines name the
`gen-*` step that writes them. A C signature change edits the Zig export, its
`symbols.zig` row, and the header prose in both the doc comment and
`tools/gen/header/*.zig`, then runs that archive's `gen-*` step.

## Git Posture

Commit, rebase, or integrate only when the user authorized it.

- One session owns one linked worktree. Read the branch with
  `git branch --show-current`; never infer it.
- Never run `git worktree add|remove|prune`, never check out `main`, `dev`, or
  another worktree's branch, and never move `main`.
- `git checkout -- <path>` and `git restore` destroy uncommitted work. Undo a
  probe from a copy saved in the scratchpad.
- Stage explicit paths after reading `git status`, never `-a`/`-u`/`add .`.
  Never amend in a shared worktree.
- Commit small on the worktree; `dev` takes one commit per change. Start with
  `.agents/skills/work/bin/glowcap-integrate --sync`. Publish without
  `--sync`: it rebases onto `main` and `dev`, squashes several commits into
  one named by `-m "<subject>"`, and compare-and-swaps `dev`.

Live CapTP from a session uses the product fronts: the
[glowcap-cli](../skills/glowcap-cli/SKILL.md),
[glowcap-mcp](../skills/glowcap-mcp/SKILL.md), and
[rooms-peer](../skills/rooms-peer/SKILL.md) skills.

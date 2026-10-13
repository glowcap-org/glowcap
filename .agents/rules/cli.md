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
  Colored output defeats text greps (a plain `grep error` can miss an
  ANSI-wrapped error), so redirect to a file and trust only the command's own
  exit code.
- Iterate on the narrowest step. Lease time and tokens are the budget every
  gate spends: the gate is the narrowest step that covers the changed
  boundary, and a combined gate for a one-file change is waste, not
  diligence. `-Dtest-filter=<name>` also skips
  analysis: code reached only by unmatched tests is never compiled, so a
  filtered green says nothing about their callers. It accepts one literal
  substring, not a comma-separated list; no matching tests is no evidence.
  `-Dtest-layer=<layer>[,<layer>]` compiles only those layers' tests, so a
  changed signature needs every layer that implements it. Run the bare suite
  once before the final gate, then combine compatible final gates
  in one invocation. Before running, name the changed boundary and which prior
  evidence it invalidates. Record command, exit status, scope, and environment
  limits in the handoff. Reuse successful evidence for unchanged inputs across
  reviews, compaction, and gate failures: rerun the affected step, preserving
  successful sibling evidence. A prose-only edit needs `source-check`; an
  executable example also needs its owning check.
- A failure gets a focused reproduction before another aggregate run (the
  [debugging skill](../skills/debugging/SKILL.md)). Zig error-set mechanics
  live in the [zig-error-sets skill](../skills/zig-error-sets/SKILL.md).
- Bound CapTP and socket work with a deadline of tens of seconds. A silent hang
  is an unbounded wait, not a slow test.
- [`docs/build-steps.md`](../../docs/build-steps.md) is the one place every
  step is documented.

## Devcontainer

The committed `.devcontainer/` is the environment of record.
[`pins.sh`](../../.devcontainer/pins.sh) and
[`checksums.sh`](../../.devcontainer/checksums.sh) own tool versions; move them
with `.devcontainer/bin/update-pins.sh`, and never weaken a check to accept an
update. A toolchain-check failure means the container is older than the image:
rebuild it, never hand-install. A browser-preparation failure names its own
remedy (rebuild only when the pin's libraries are newer than the image's).
The four AI harnesses are
the exception: they are managed tools, not image content — update them with
`.devcontainer/bin/tools.sh` (never by hand), and a harness pin bump needs the
cold-seed smoke run, not a rebuild. Playwright's browsers are the same shape
one step further: the shared browser prerequisite prepares the checkout's
exact pinned requirement through `tools.sh ensure playwright`, and browser
steps run under `tools.sh exec playwright --`, which supplies the resolved
browser directory — never set `PLAYWRIGHT_BROWSERS_PATH` by hand. Zig's cache
lives in the per-worktree
`glowcap-dev-<worktree>-zig-work` volume; `zig-out/` stays at the worktree
root. [The environment notes](../../.devcontainer/README.md) own every
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
`tools/gen/header/*.zig`, then runs that archive's `gen-*` step. Every
archive fingerprint reflects the shared layouts, so a change under
`src/c_abi/shared` also stales the binding constants, the Rust layouts and
every header that embeds a fingerprint. Run all the `gen-*-check` steps that
`docs/build-steps.md` lists in one invocation, then regenerate each one that
fails.

## Git Posture

Commit, rebase, or integrate within the user's authorized scope. A request to
commit for another agent's handoff includes integration into local `dev`.

- One session owns one linked worktree. Read the branch with
  `git branch --show-current`; never infer it.
- Never run `git worktree add|remove|prune`, never check out `main`, `dev`, or
  another worktree's branch, and never move `main`.
- `git checkout -- <path>` and `git restore` destroy uncommitted work. Undo a
  probe from a copy saved in the scratchpad.
- Stage explicit paths after reading `git status`, never `-a`/`-u`/`add .`, and read
  `git diff --cached --stat` against the intended change before committing. The
  integrate gate catches a dirty tree, not a mis-staged one.
  Never amend in a shared worktree.
- Commit messages name the change and its reason in the repository's ordinary
  voice. Never add provenance or assistance trailers (`Co-Authored-By` and
  friends): the maintainer decides what a commit says about how it was made,
  and [`PROVENANCE.md`](../../PROVENANCE.md) owns the disclosure. Existing
  trailers in history stay.
- Commit small on the worktree; `dev` takes one commit per change. Start with
  `.agents/skills/work/bin/glowcap-integrate --sync`. Publish without
  `--sync`: it rebases onto `main` and `dev`, squashes several commits into
  one named by `-m "<subject>"`, and compare-and-swaps `dev`.

Live CapTP from a session uses the product fronts: the
[glowcap-cli](../skills/glowcap-cli/SKILL.md),
[glowcap-mcp](../skills/glowcap-mcp/SKILL.md), and
[rooms-peer](../skills/rooms-peer/SKILL.md) skills.

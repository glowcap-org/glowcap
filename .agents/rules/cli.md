---
description: "Execution model: gates, the devcontainer front, generated state, and git posture."
alwaysApply: true
---

# glowcap — Execution Model

## Gates

Run every gate from the repository root through the front, as in
`.agents/skills/work/bin/glowcap-dev zig build check`. The front enters this
worktree's devcontainer (the pinned toolchain), applies the per-test deadline,
and holds one build lease per worktree. When a contender exits 75, inspect the
owner it names before changing code. Set `GLOWCAP_BUILD_LEASE_TIMEOUT` only
when waiting is the work.

The aggregate gates and what each covers are listed under [Everyday steps and
checks](../../docs/build-steps.md#everyday-steps-and-checks), the one place
every step is documented. Choose evidence by the boundary that changed:

- Read a gate's result from its own exit code. Redirect output to a file
  instead of piping to `tail`/`grep`: a pipe reports the last command's status,
  a green log can echo `failed command:` stderr, and color codes hide errors
  from a plain `grep error`.
- Run the narrowest step that covers the changed boundary. Lease time and
  tokens are the budget, so a combined gate for a one-file change is waste.
- `-Dtest-filter=<name>` takes one literal substring and skips analysis: code
  reached only by unmatched tests is never compiled, so a filtered green says
  nothing about their callers. No matching tests is no evidence.
- `-Dtest-layer=<layer>[,<layer>]` compiles only those layers' tests, so a
  changed signature needs every layer that implements it.
- Run the bare suite once before the final gate, then combine compatible final
  gates in one invocation.
- Take options from the owning phase in `ci/gates.sh`; gates with different
  optimization modes need separate invocations.
- Before running, name the changed boundary and the prior evidence it
  invalidates. After a review, compaction, or gate failure, rerun only the
  affected step and keep successful sibling evidence for unchanged inputs.
- Record command, exit status, scope, and environment limits in the handoff.
- A prose-only edit needs `source-check`. An executable example also needs its
  owning check.
- Reproduce a failure with a focused run before another aggregate run (the
  [debugging skill](../skills/debugging/SKILL.md)). Zig error-set mechanics
  live in the [zig-error-sets skill](../skills/zig-error-sets/SKILL.md).
- Bound CapTP and socket work with a deadline of tens of seconds. A silent hang
  is an unbounded wait, not a slow test.

## Devcontainer

The committed `.devcontainer/` is the environment of record.
[The environment notes](../../.devcontainer/README.md) own every procedure.

- [`pins.sh`](../../.devcontainer/pins.sh) and
  [`checksums.sh`](../../.devcontainer/checksums.sh) own tool versions. Move
  them with `.devcontainer/bin/update-pins.sh` and never weaken a check to
  accept an update.
- A toolchain-check failure means the container is older than the image.
  Rebuild it and never hand-install.
- A browser-preparation failure names its own remedy. Rebuild only when the
  pin's libraries are newer than the image's.
- The four AI harnesses are managed tools, not image content. Update them with
  `.devcontainer/bin/tools.sh`, never by hand. A harness pin bump needs the
  cold-seed smoke run, not a rebuild.
- Playwright's browsers follow the same shape: the shared browser prerequisite
  prepares the checkout's pinned requirement through `tools.sh ensure
  playwright`, and browser steps run under `tools.sh exec playwright --`, which
  supplies the resolved browser directory. Never set `PLAYWRIGHT_BROWSERS_PATH`
  by hand.
- Zig's cache lives in the per-worktree `glowcap-dev-<worktree>-zig-work`
  volume. `zig-out/` stays at the worktree root.

## Generated State

Never committed. `source-check` holds each against `.gitignore` and the index:

- `.zig-cache/`
- `zig-out/`
- `zig-pkg/`
- `.serena/cache/`
- `.serena/logs/`
- `.serena/memories/`
- `bindings/rust/target/`
- `bindings/rust/Cargo.lock`

Committed FFI tiers and headers are generated, and their first lines name the
`gen-*` step that writes them. A C signature change edits the Zig export, its
`symbols.zig` row, and the header prose in both the doc comment and
`tools/gen/header/*.zig`, then runs that archive's `gen-*` step. Every archive
fingerprint reflects the shared layouts, so a change under `src/c_abi/shared`
also stales the binding constants, the Rust layouts, and every header that
embeds a fingerprint. Run all the `gen-*-check` steps that
`docs/build-steps.md` lists in one invocation, then regenerate each one that
fails.

## Git Posture

[`docs/maintaining.md`](../../docs/maintaining.md) owns the promotion and
publication workflow. Local integration into `dev` is distinct from
publication. Only the promote workflow moves `main`, and an agent review is
never human approval. Remote actions still require the maintainer's direction.

Commit, rebase, or integrate within the user's authorized scope. A request to
commit for another agent's handoff includes integration into local `dev`.

- One session owns one linked worktree. Read the branch with
  `git branch --show-current`, never infer it.
- Never run `git worktree add|remove|prune`, check out `main`, `dev`, or
  another worktree's branch, or move `main`.
- `git checkout -- <path>` and `git restore` destroy uncommitted work. Undo a
  probe from a copy saved in the scratchpad.
- Stage explicit paths after reading `git status`, never `-a`/`-u`/`add .`.
  Read `git diff --cached --stat` against the intended change before
  committing, because the integrate gate catches a dirty tree, not a
  mis-staged one. Never amend in a shared worktree.
- Commit messages name the change and its reason in the repository's ordinary
  voice. Never add provenance or assistance trailers (`Co-Authored-By` and
  friends): the maintainer decides what a commit says about how it was made,
  and [`PROVENANCE.md`](../../PROVENANCE.md) owns the disclosure. Existing
  trailers in history stay.
- Commit small on the worktree, because `dev` takes one commit per change.
  Start with `.agents/skills/work/bin/glowcap-integrate --sync`. Publish
  without `--sync`: it rebases onto `main` and `dev`, makes one commit from
  the branch's tree (several commits squash under `-m "<subject>"`), signs it
  with the maintainer's key, and compare-and-swaps `dev`. Without a reachable
  signing key it refuses and moves nothing, so a worktree commit needs no
  signature of its own. It refuses a decision record id the rebased tree
  holds twice, because another tree may have taken the number you took:
  renumber yours and retry.

Live CapTP from a session uses the product fronts: the
[glowcap-cli](../skills/glowcap-cli/SKILL.md),
[glowcap-mcp](../skills/glowcap-mcp/SKILL.md), and
[rooms-peer](../skills/rooms-peer/SKILL.md) skills.

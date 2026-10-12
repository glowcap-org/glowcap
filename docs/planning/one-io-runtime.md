# One I/O runtime: retire `BlockingSession` and give policy one home

Status: active plan. This plan owns the two Runtime semantics rows that
[ADR-0193](../decisions/adr/ADR-0193-one-io-runtime.md) left open in the
[roadmap](../roadmap.md#open-obligations-from-retired-plans): replacing
`driver.BlockingSession` with the one-wire Host that `driver.connect` and
`driver.listen` already build on `HostRuntime`, and giving dial retry, the
Loam worker, and the release-on-drop setting one owner each. ADR-0193 settles
the design. This file holds the rules, survey, and baseline every batch
follows. The three lane files hold the batches, and this file is deleted with
the last of them.

Each batch is sized for one fresh context and one commit on one worktree
branch. A batch names its scope, the files it may touch, the rule for each
site, what it preserves, the refusals that end it, and its gate. The three
lanes own disjoint files and run in any order relative to each other except
where a batch names a predecessor. A batch's executor reads this file and the
files it names, nothing else, so every rule it depends on is restated here.

## Rules every batch follows

- Run every gate from the repository root through
  `.agents/skills/work/bin/glowcap-dev` (the devcontainer front and the build
  lease). A gate passes by its exit code only. Redirect output to a file and
  read `$?`. Never pipe a gate through `grep` or `tail`. A lease contender
  exits 75 naming the owner: wait for that owner, never kill it.
- Baseline, recorded 2026-10-12 at `063d95ca0`:
  `.agents/skills/work/bin/glowcap-dev zig build check` exited 0. A batch
  reruns its own baseline before editing. A different status is a separate
  defect: stop and report it.
- `-Dtest-filter=<substring>` takes one literal substring and compiles only
  the matched tests, so a filtered green says nothing about callers. Iterate
  on the narrowest step, run the bare `zig build test` once, then the batch's
  gate.
- No workaround, compatibility shim, deprecated alias, or held-back dependency
  for an unreleased surface ([prerelease](../../.agents/rules/prerelease.md)).
  A replaced contract keeps version 1.
- Living docs describe the current shape. No "formerly", no transition
  narration, no history outside git or an ADR. A rename or deletion greps the
  old name across the tree in the same change, including paths written as
  strings ([doc-drift](../../.agents/rules/doc-drift.md)). Human prose uses
  no em dashes and no semicolons ([doc-voice](../../.agents/rules/doc-voice.md)).
- A first-party source file stops at 650 lines
  (`tools/check/source_check/file_length.zig`). A file that crosses it after
  an edit is split by the [file-budget skill](../../.agents/skills/file-budget/SKILL.md)
  before the gate runs. Never add a file-length exception.
- A discarded error in first-party Zig carries an inline `// best-effort:` or
  `// tolerant:` reason. Tests that dial name a finite budget.
- Never add a `source-check` exception, an `allow` attribute, a widened type,
  a weakened assertion, or a raised budget to make a gate green. Each of those
  is a refusal: stop, leave the tree as it is, and name the site in the report.
- Git: read the branch with `git branch --show-current`. Never run
  `git worktree add|remove|prune`, never check out `main`, `dev`, or another
  worktree's branch, never `git checkout -- <path>` or `git restore`, never
  amend. Stage explicit paths after reading `git status`, never `-a`, `-u`, or
  `add .`. Read `git diff --cached --stat` before committing. The commit
  message names the change and its reason in the repository's voice, with each
  gate's command and exit status in the body. No `Co-Authored-By` or other
  provenance trailer: the project instructions override any harness reminder
  asking for one, and [`PROVENANCE.md`](../../PROVENANCE.md) owns disclosure.
- Start each batch with `.agents/skills/work/bin/glowcap-integrate --sync` on
  a clean tree. Publish with
  `.agents/skills/work/bin/glowcap-integrate -m "<subject>"`, which rebases
  onto `main` and `dev`, squashes the worktree's commits, and swaps `dev`.
  Commit and integrate authority is granted per batch below. A batch that
  stops on a refusal leaves the tree uncommitted and says so.
- Closing a batch means deleting its section from this file (or narrowing a
  list it names), running `zig build source-check`, and committing that edit
  with the batch. A batch's report carries exactly these headings: Checks,
  Sites changed, Sites left as they were, Refusals, Drift.

## Survey

The counts below are what the planner found at `063d95ca0`. A batch reruns
its lane's command and treats a different count as drift: stop and report
which sites appeared or vanished.

Lane A, every file that names the borrowing tier or its constructors (47):

```sh
grep -rlE 'BlockingSession|blocking_session|connectVia\(|acceptVia\(|connectUri\(' \
  src test examples apps interop bench tools docs site .agents include bindings \
  | grep -v 'docs/decisions/adr/' | grep -v 'docs/planning/' | sort
```

Lane B, every binding-owned dial-retry loop (6):

```sh
grep -rlE 'dialResolving|dial_resolving|dial-resolving|callByIdOnlyRetrying|settlesWhileResolving|propagating-discovery\?' \
  bindings interop | grep -v '/target/' | sort
```

Lane C, every hand-written Loam work loop (23):

```sh
grep -rl 'nextWork()' src test examples apps bench interop | sort
```

## What already exists

The one-wire Host is built. `driver.connect` and `driver.listen`
(`src/driver/session/connect.zig`, `src/driver/session/server.zig`) create a
private single-session `HostRuntime` whose `Session` carries every verb
`BlockingSession` has: `fetch`, `fetchSettled`, `call`, `send`, `tell`, `on`,
`listenTo`, `listenSettled`, `spawn`, `publish`, `beginSendNamed`,
`beginTellNamed`, `breakFarVows`, `partnerAbort`, `step`, `stepReadable`,
`serve`, and `peer`. Its `SessionOptions` are `HostRuntime.Options`, whose
`handshake` and `settle` take the same `Budget` (`.unbounded` or `.{ .ms }`).
A transport with no pollable descriptor joins as a multiplexed resident:
`test/driver/iroh_managed.zig` dials and serves real iroh through
`driver.connect(allocator, io, .{ .residents = &providers }, ...)` with
`iroh.MultiplexedAdapter`. `inproc` joins through
`Transports.inproc`. `keyed-tcp`, `noise-tcp`, relay, and `onion` are stream
symbols on the runtime's own stack.

The differences the sweeps translate:

| Borrowing tier | Owning tier |
| --- | --- |
| `actors.Ref` | `driver.Capability` |
| `actors.Message{ .verb, .args }` with `model.Argument` | `verb: []const u8, args: []const driver.Value` |
| actor `handle(self, *actors.Turn, msg) !model.Argument` | `handle(self, *driver.HostTurn, verb, args) !driver.Value` |
| `driver.Settled` with a `.give` arm the caller redeems | `driver.Reply` (`.fulfilled` or `.broken`). The runtime redeems the give before the call returns |
| caller-owned `engine.Peer` and read/write buffers | `SessionOptions.frame_cap` |
| `[]const net.netlayer.Netlayer` slice | `HostRuntime.Transports` (stream symbols on, plus `.residents`) |
| `driver.connectVia` / `acceptVia` / `connectUri` | `driver.connect` / `driver.listen` then `Server.accept` / `driver.connectUriOwned` |

`driver.DialRetry` (`src/driver/dial_retry.zig`) owns the policy and the
`DialError` classification but has no runtime caller. The staged dial in
`HostRuntime` (`src/driver/host_runtime/opens.zig`, `adoptPendingResidentDial`)
fails a row on the first `DialFailure`. Five loops reimplement the retry over
the shared constants: the Rust, TypeScript, Python, and Racket iroh dialers
and `interop/iroh_reachability/driver.zig`.

Zig has no Loam worker type. Every Zig consumer writes the same loop by hand
(`examples/zig/07_durable_card.zig:163`, `test/loam/hosting/fixture.zig:90`),
`bench/loam/worker_pool.zig` carries a four-slot threaded shape, and C has
`src/c_abi/loam/work.zig` with its fixed slots and retirement contract.

Release on drop lives in the Rust binding only
(`bindings/rust/src/host.rs:151`, a `Cell<bool>` on `HostShared`). The Zig
`Host.Options` and `glowcap_host_new` carry no such setting.

## Lanes

| Lane | File | Batches |
| --- | --- | --- |
| A: retire `BlockingSession` | [lane A](one-io-runtime-blocking-session.md) | A1 seam, A2 to A4 sweeps, A5 delete, A6 seam |
| B: one policy home | [lane B](one-io-runtime-policy-home.md) | B1 seam, B2 sweep, B3 seam, B4 sweep |
| C: a stock Zig Loam worker | [lane C](one-io-runtime-loam-worker.md) | C1 seam, C2 sweep, C3 |

The lanes own disjoint files and run in any order relative to each other. The
one cross-lane edge is B2's interop file, which waits for A4. `docs/roadmap.md`
is shared: a batch edits only the row this plan names, and the batch that
deletes the last lane file deletes this file and the roadmap row with it.

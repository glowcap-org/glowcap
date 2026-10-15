---
id: ADR-0214
status: accepted
date: 2026-10-13
tags: [engine, driver, runtime, performance, gc]
decision: "A questioner's answer releases with no message behind them wait at the peer's queue tail. The session's next message carries them ahead of itself in one `op:gc-answers`, and an embedder about to park flushes them through the Host, so the release costs a hot caller no send of its own and an idle caller's partner frees the answer at that caller's park."
supersedes: []
superseded_by: []
amends: [ADR-0220]
amended_by: []
---

# ADR-0214 Answer releases ride the next message

## Context

After [ADR-0213](ADR-0213-a-turn-submits-at-the-park.md) one `tcp` call
round trip through `driver.Session` still cost the client two sends: its
`op:deliver` at the park, and a one-position `op:gc-answers` encoded by the
feed that settled the answer and flushed as `call` returned. That second
segment was the server's second receive and second wake per call, and on one
CPU the two extra context switches were the largest remaining item in the
2.2× gap against the round trip's floors.

The CapTP specification (§ `op:gc-answers`) lets a questioner release a
resolved answer when it chooses, and Goblins releases at garbage-collection
time. Timing is the questioner's policy, and a release is the one outbound
item no one waits for.

## Decision

`engine.Peer.step` holds a run of answer-release carriers that reaches the
queue tail: `outbound_drain.holdsAnswerReleases` sees only releases ahead of
the tail and `step` reports idle. The next message published behind them
makes the run ordinary queue work again, and the release arm encodes the
whole run as one `op:gc-answers` of up to 32 positions ahead of that
message, so the two leave in one write and one send. `Peer.flushAnswerReleases`
encodes a held run on demand.

The Host learns of a held run where it drives the session: `drainWork` asks
the peer after each `driveFedBudgeted` and enrolls the session in
`Host.held_releases`, a worklist reserved like `pending_flush` with an
intrusive bit on the shell. `Host.flushHeldReleases` encodes every held run,
queues each session's flush action, and is the verb an embedder calls when it
is about to park.

- The blocking `HostRuntime` face calls it at the top of `waitAnySource`, so
  the next verb's message can still carry the release, and an idle caller's
  partner frees the answer when that caller next parks.
- The stepped face parks outside the runtime, so every action drain there
  flushes first, which keeps a step's releases leaving as that step returns.
- The raw C host's `glowcap_host_next_action` flushes when its queue runs
  dry, since that is where a C embedder parks, and returns the flush it
  queued as the last action.

A closed session holds nothing: the ordinary step discards its run, and
teardown removes the shell from the worklist.

## Scope (what this does not decide)

- Releases of the answers a host serves (`op:gc-exports`, the stateless
  policy in `driver/core/gc.zig`): they leave with the turn that produced
  them, as before.
- A time bound on a held release. A blocking-face application that releases
  an answer and then runs no verb holds that one release until its next
  park, and the partner keeps one answer row for as long. The row is bounded
  by the session's answer table and freed with the session.

## Alternatives Considered

- Hold releases in the engine until a count fills (a holdback of 32).
  Rejected: an idle session would hold its partner's answer rows for the
  session's life, and the reservation's outbound charge would sit against
  the session's budget with nothing to retire it.
- Defer the Host's encode of a release to the park and keep the engine
  eager. Rejected: the feed that settles an answer drives the session
  anyway, so the engine would still encode the release in that turn.
- Flush held releases inside `nextAction` for every caller. Rejected: the
  runtime drains through the same verbs at every verb's end, which would put
  the release back in its own send on the blocking face.

## Consequences

- One `tcp` call round trip is one send per side: the client's
  `op:gc-answers` for call N rides ahead of call N+1's `op:deliver`.
- A released answer's row stays in the questioner's outbound answer table
  until the release is encoded, so a test that releases and then counts rows
  pumps through a park first (the core-host harness flushes when its action
  drain runs dry, as a C embedder does).
- `Peer.step` can report idle with carriers queued. Code that asks whether a
  peer has queued work asks `holdsAnswerReleases` beside it.

## Evidence and gate

- `test/engine/peer/answer_release_test.zig`: releases wait, ride ahead of
  the next message in one frame, and a flush sends them alone.
- `test/driver/core_host/answer_release_test.zig`: the Host holds a settled
  call's release, the next send carries it ahead of the deliver, and
  `flushHeldReleases` sends a held release at the park.
- Syscalls per `tcp` round trip under `strace -f -c` on the benchmarks page's
  machine: 4 ring enters and 2 parks before, 3 ring enters and 2 parks after,
  with the client's one enter submitting its send and its re-armed receive
  together. The pinned p50 fell from 13.7 µs to 11.5 µs, 1.8× the floors it
  pays, and `bench/README.md` holds the row.

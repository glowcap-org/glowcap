# pancake ↔ Goblins benchmark suite — design

Role: a historical record. This design produced the benchmark suite that now
ships under `bench/goblins/` and runs via `zig build bench-goblins`. It
describes the shape as proposed, not the current code; `bench/goblins/README.md`
is the living description of what shipped.

## Goal

Compare pancake against Spritely Goblins on equal terms: write a benchmark
application once in capability/actor terms, run that _same_ application on both
substrates over the same transport, and measure the metrics people use to judge
an IO server — latency, throughput, connection scaling, and memory.

pancake is consumed through its Racket binding (`bindings/racket/pancake.rkt`),
which already exposes a Goblins-shaped actor surface (`spawn`, `$`, `<-`, `on`,
`methods`, `bcom`) over the OCapN peer. Goblins is consumed natively through the
`goblins` collection. The comparison is therefore "the same actor application,
on pancake's Zig protocol core versus Goblins' native-Racket runtime."

## Verified foundation (not assumed)

These were checked by running code in the devcontainer, not taken from prose:

- `zig build racket-goblins-interop` completes a keyed OCapN handshake, a
  bootstrap fetch, and an echo deliver/resolve against a _live_ Goblins vat over
  TCP. The Racket binding genuinely talks to real Goblins.
- A throwaway Goblins echo client/server over loopback TCP (built on
  `conformance/goblins-peer/racket/tcp-netlayer.rkt` + `spawn-mycapn` +
  `register`/`enliven`) runs 2000 sequential round-trips and reports latency,
  throughput, and memory.
- A throwaway pancake echo client/server over loopback TCP (built on the
  binding's `listen`/`accept`/`connect`/`conn-publish`/`conn-fetch` surface)
  does the same.

The probes also exposed a fairness trap (see below), which is the reason this
design exists rather than just shipping the probes.

## Fairness principle

The probes were not yet fair: the pancake client used a hand-written blocking
send→flush→read→dispatch loop while Goblins routed every message through its
full vat event loop and promise machinery. That measures a tight hand-coded loop
against a complete actor runtime. The suite holds these lines instead:

1. **One application source per suite.** The actor behavior (constructors,
   methods, `bcom`, the client's send/observe logic) is written once and loaded
   unchanged on both substrates. The only per-substrate code is bootstrap and
   driving, which is off the measured path.
2. **Same programming model.** The application expresses work as eventual-sends
   (`<-`) and promise observers (`on`), the idiomatic Goblins way. Neither
   substrate gets a privileged synchronous fast path the other lacks.
3. **Same driving model.** Goblins drains turns through its vat loop
   automatically. pancake is sans-io, so the harness gives it a _general_ pump
   that runs the connection/vat to quiescence (drive queued turns, flush
   outbound, read+dispatch inbound until the outstanding promises settle). This
   pump is the fair analog of Goblins' scheduler — general, not per-message.
4. **Same wire and configuration.** Syrup over loopback TCP on both, equal
   default frame and buffer sizes, both warmed, multiple timed trials.
5. **The substrate is the only intended difference.** pancake ships a compiled
   Zig protocol core consumed from Racket; Goblins is native Racket. That
   asymmetry _is_ the comparison and is fair precisely because everything above
   it is identical.

Reporting follows the existing bench convention (`bench/codec_bench.zig`):
numbers are printed, never gated on a wall-clock threshold.

## The suites

Each suite is a complete shared application. `echo` is a calibration baseline;
the other three are "worth benchmarking" because they exercise what CapTP exists
for — passing capability references across the wire, invoking them, stateful
actors, and promise pipelining.

| Suite                      | Application                                                                                                                 | What it exercises                                                           |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| S0 · echo                  | one actor returns its argument                                                                                              | raw round-trip + runtime overhead (calibration)                             |
| S1 · registry + pipelining | a registry actor hands back capability references; client invokes them, including a pipelined call on an unresolved promise | cross-wire references, method dispatch, promise pipelining, stateful actors |
| S2 · mint/purse            | a mint creates purses (capabilities); deposit/withdraw move balances; purses pass as references between parties             | capability passing as arguments, stateful turns, classic ocap shape         |
| S3 · task board            | `create` returns a task capability; `assign`, `complete`, `list`                                                            | realistic mixed-method workload mirroring pancake's cross-language demos    |

## Metrics

Applied to every suite on both substrates. The shared metrics module is pure
Racket and backend-agnostic.

- **Latency.** N sequential round-trips; report p50 / p99 / p999 over multiple
  trials, plus mean. Each round-trip is one `<-` whose promise the harness waits
  on before issuing the next.
- **Throughput.** A window of W in-flight `<-` sends drained by the substrate's
  loop; report messages/second at the W that saturates, plus the W used.
- **Connections.** Open C concurrent client connections to one server; report
  total and per-connection keyed-handshake setup time and the setup rate
  (connections/second).
- **Memory.** Sample the _server process_ RSS (`/proc/<pid>/status` VmRSS and
  VmHWM) at baseline (0 connections) and with C live connections; report the
  baseline, the steady total, and the derived bytes-per-connection. A heavier
  application (more live exports) is expected to cost more per connection, so
  this is reported per suite, not once.

## Components and layout

New directory `bench/goblins/`:

```
bench/goblins/
  README.md                  role + how to run + fairness notes (living-state)
  metrics.rkt                percentiles, throughput math, /proc RSS sampling (backend-agnostic)
  pump.rkt                   the pancake "run-to-quiescence" driver (the fair scheduler analog)
  backend-goblins.rkt        re-exports {spawn,$,<-,on,methods,bcom} + bootstrap verbs from goblins
  backend-pancake.rkt        re-exports the same names from bindings/racket/pancake.rkt
  apps/
    echo.rkt                 shared actor behavior for S0
    registry.rkt             shared actor behavior for S1
    mint.rkt                 shared actor behavior for S2
    taskboard.rkt            shared actor behavior for S3
  server-goblins.rkt         goblins server bootstrap (tcp-netlayer + spawn-mycapn + register)
  server-pancake.rkt         pancake server bootstrap (listen/accept/conn-publish/conn-serve)
  client.rkt                 backend-parameterized client driver running the four metrics
  bench.rkt                  orchestrator: spawns each server process, runs clients, prints comparison + writes report
```

The actor-behavior files under `apps/` `(require)` a backend module that
supplies `{spawn,$,<-,on,methods,bcom}`, so a single behavior source loads on
both substrates. The server bootstrap and client driver differ per substrate but
contain no application logic.

### Why this split

- The thing being measured (actor behavior + client send/observe logic) is
  provably identical because it is one file.
- The substrate-specific wiring is small, off the hot path, and clearly
  separated, so a reader can see that no fast path leaked into one side.
- The metrics and the pump are shared, so both substrates are measured by the
  same instrument.

## Transport and process model

- Loopback TCP on both substrates (matches the existing `racket-goblins-interop`
  setup and the Goblins `tcp-netlayer`).
- The server runs in its **own OS process** so its RSS is attributable. The
  orchestrator spawns it, waits for an NDJSON readiness line (the pattern
  `conformance/goblins-peer/racket/goblins-host.rkt` already uses), then runs
  the client workloads against it, then tears it down.
- Client workloads run in their own process and open real TCP connections.

## Build integration

- New step `zig build bench-goblins` runs the orchestrator. It needs `racket`
  and the `goblins` collection on PATH, so it is a **sibling of `check`, never a
  dependency of the hermetic gate** — exactly like the `*-goblins-interop`
  steps. A contributor with only a Zig toolchain is never blocked by it.
- `-Dbench-suite=<echo|registry|mint|taskboard|all>` selects a suite (default
  `all`). `-Dport=N` pins the base port like the interop steps.
- A `--smoke` mode runs each suite with tiny counts to prove the harness still
  runs cheaply, so a liveness check can be wired later without wall-clock
  flakiness entering `check`.
- The report writes under `zig-out/bench-reports/` (already git-ignored,
  matching `bench-peer-scaling`).

## Documentation and meta-check obligations (same change)

- `bench/goblins/README.md` is a living-state surface: it states the role, the
  fairness principle, and the run commands, and is registered in the doc-drift
  living-state table.
- The `cli` rule (`.agents/rules/cli.md`) gains the `bench-goblins` step in its
  command inventory; `tools/meta_check.zig` enforces that every documented
  `zig build` step is real and every real step is documented, so the step and
  its doc land together.
- Any `docs/` surface that inventories benchmarks (e.g. a benchmarks section in
  `docs/boundaries.md` or `docs/ladder.md`) is updated to mention the
  cross-implementation comparison and that its numbers are reported, not gated.

## Explicitly out of scope (named boundaries, not omissions)

- **A full Goblins-compatibility library.** The suite shares only the actor
  surface a benchmark app needs (`{spawn,$,<-,on,methods,bcom}` + the small
  bootstrap verbs). Running arbitrary unmodified Goblins programs (machines,
  full sturdyref/pipelining/error taxonomy, vat lifecycle) is a much larger
  surface and is not built here.
- **A wall-clock performance gate.** This suite reports numbers; it does not
  assert thresholds. A gated, hardware-stable threshold is separate roadmap work
  (`docs/roadmap.md`, "Enforced wall-clock performance gate").
- **Non-loopback transports** (iroh, real networks). Loopback only, to keep the
  comparison about the protocol core and runtime rather than the network.
- **Cross-process distribution beyond one server + clients on one host.**

## Risks and how the design answers them

- **Hidden unfairness.** Answered structurally: one shared app file, a general
  pump rather than a per-message loop, a shared metrics instrument, and a layout
  that makes any leaked fast path visible in review.
- **Goblins API drift across versions.** The suite pins to the installed
  `goblins` (v0.18.0 verified). The backend-goblins shim is the single place a
  version change is absorbed.
- **Noisy timing.** Multiple trials, warmup, reported percentiles, and an
  acknowledgement that absolute numbers are environment-dependent; the
  pancake-vs-Goblins _ratio_ on one host is the durable signal.
- **Memory attribution.** Server in its own process; RSS read from `/proc`;
  bytes-per-connection derived from baseline vs. loaded, not guessed.

# Cross-implementation benchmark: pancake vs Spritely Goblins

One shared Racket application, run unchanged on two OCapN substrates — pancake's
Racket binding and [Spritely Goblins](https://spritely.institute/goblins/) — and
compared on latency, throughput, connection setup, and server memory. The point
is a _fair_ head-to-head: the only variable between two runs is the substrate
underneath the same application.

For the opposite question — one fixed pancake host, the _client language_
swapped per row — see the per-language consumer-cost bench in
[`../langs/README.md`](../langs/README.md) (`zig build bench-langs`). That one
measures the cost of consuming pancake from each language; this one measures the
substrate.

Run it (needs `racket` and the `goblins` collection on PATH):

```sh
zig build bench-goblins                      # full run, all four suites
zig build bench-goblins -- --smoke           # tiny counts, fast sanity check
zig build bench-goblins -- --suite=registry  # one suite
zig build bench-goblins -- --suite=echo --smoke
```

The orchestrator spawns each server as its own OS process, waits for a readiness
line, drives it, samples its memory, and tears it down. A comparison prints to
the terminal, and four artifacts land under `zig-out/bench-reports/`, all
stamped with the run's epoch second:

- `goblins-compare-<stamp>.txt` — the terminal report.
- `goblins-compare-<stamp>.md` — a Markdown report: a value table plus Mermaid
  `xychart-beta` bar charts (latency p50, throughput) that render on Codeberg
  and GitHub, with the SVGs referenced by relative name.
- `goblins-compare-<stamp>-latency.svg`, `-throughput.svg` — standalone grouped
  bar charts (Goblins vs pancake per suite), no JavaScript, themed to match the
  site's diagrams. Drop one into a page or open it directly.

The reports are generated, not committed: each is a single machine on a single
run, so there is no frozen leaderboard in the tree. You render the numbers you
measured. [`report.rkt`](report.rkt) owns the Markdown and SVG rendering.

## The fairness principle

A benchmark is only worth reading if the substrate is the _only_ thing that
differs between two runs. Four things are held identical across pancake and
Goblins, so the gap a run reports is the substrate's and nothing else:

- **Same application source.** The four apps in [`apps/`](apps/) are written
  against a backend-blind contract and never import either substrate. A method
  table is built by [`dispatch.rkt`](dispatch.rkt) — a plain function that does
  the job of the `methods` macro both substrates ship, without binding to
  either.
- **Same programming model.** Both backends expose the same five verbs
  (`server-run`, `client-connect`, `client-fetch`, `client-call`,
  `client-close`). A capability the server returns is minted through a
  backend-supplied `mint-cap`: on Goblins a returned actor reference
  auto-marshals, so `mint-cap` is `spawn`; on pancake it exports and publishes
  the actor, so `mint-cap` is `conn-spawn`. The app calls `mint-cap` either way.
- **Same driving model.** One client unit is one synchronous _send + settle_:
  issue an eventual-send and run the substrate until the reply settles. On
  pancake that is the binding's own `conn-send` (it pumps the sans-io peer to
  quiescence); on Goblins it is an eventual-send awaited on the vat. Neither
  side gets a hand-tuned fast path the other lacks.
- **Same transport.** Both run over real loopback TCP, server and client in
  separate OS processes — and over the _identical_ TCP stack: the pancake
  binding's `connect`/`listen`/`accept` and the Goblins netlayer both use
  Racket's `tcp-connect`/`tcp-listen`/`tcp-accept` with default socket options.
  Neither disables Nagle, neither tunes buffers; the transport is held constant
  so a latency gap reflects the protocol and runtime above it, not a socket
  flag.

### Measurement hygiene (applied identically to both)

- **Warmup.** Both substrates are Racket/Chez; the first few hundred units pay
  JIT and initial-heap-growth costs, and Goblins has more code to warm. Each
  measured phase runs a generous warmup (up to 500 units) first, so the window
  reflects steady state, not startup. Without warmup, JIT compilation and
  one-time heap growth land inside the measured window and inflate p99 tails.
- **GC settle.** After warmup, a full collection runs before the measured window
  opens, so warmup garbage is reclaimed outside the window. Per-operation GC
  _during_ the window is still measured — it is a real cost of a substrate's
  allocation rate — so Goblins is not given a pass on the collection its own
  allocation triggers.
- **No per-call driver overhead asymmetry.** The Goblins driver reuses one
  settle channel across calls, matching the pancake side's single result cell,
  so the measured cost is the substrate's, not the harness's allocation.

## The suites

Each suite is a self-contained app under [`apps/`](apps/), selected by
`--suite`. They climb from a calibration baseline to full capability passing:

- **`echo` (S0)** — calibration. One round-trip returning its argument; no
  capability passing. Isolates raw request/reply cost.
- **`registry` (S1)** — `lookup` mints a cell capability holding the key and
  returns it; the client then invokes `get` on that returned capability. Two
  sequential round-trips that pass a live capability across the connection.
- **`mint` (S2)** — the classic mint/purse. `make-purse` returns a fresh purse
  capability; the client deposits into it. Capability creation plus stateful
  turns.
- **`taskboard` (S3)** — `create` returns a task capability driven through
  `assign`, then `complete`, then `status`. A returned capability invoked
  several times.

### S5 — snapshot / restore (local time-travel)

S5 measures local time-travel, not a wire conversation: pancake's
`Vat.snapshot`/ `restore` (ADR-0060) against Goblins' `snapshot-whactormap`.
Because it is a local actormap operation — and pancake does not project
snapshot/restore over the C ABI the Racket binding drives — the two runtimes are
measured **natively**, side by side, rather than through the shared
`server`/`client` harness above:

- pancake — `zig build bench-snapshot` (Zig,
  [`../snapshot_bench.zig`](../snapshot_bench.zig)); writes
  `zig-out/bench-reports/snapshot.md`.
- Goblins — `racket bench/goblins/snapshot.rkt`
  ([`snapshot.rkt`](snapshot.rkt)); needs `racket` + `goblins`.

Both print the same `*_by_objects` / `*_by_bytes` lines, so the numbers line up
directly. Both validate the same claim: a snapshot is **O(objects)** and copies
no state bytes (snapshot time grows with object count and stays flat as the
bytes-per-object grow), because each shares state by reference rather than deep
copying. S5 surfaces one difference: Goblins's share-by-reference is automatic
for every actor and paid for by always-immutable behaviors plus GC; pancake's is
**opt-in per actor and off by default**, so a non-snapshotting actor pays
nothing, and the cost of sharing a mutable actor is deferred to a copy-on-write
on first mutation after a snapshot. The Zig bench reports that off-by-default
per-turn cost and the one-time COW alongside the snapshot sweep.

## The metrics

- **Latency** — N units; p50 / p99 / p999 / mean in milliseconds.
- **Throughput** — N units back-to-back; requests per second.
- **Connections** — open many sessions and fetch the root on each; total and
  per-connection setup time. Each session is a distinct CapTP connection (for
  Goblins, a distinct client vat + netlayer, the same shape as one pancake
  connection).
- **Memory** — the server process's resident set (`VmRSS` from `/proc`) with the
  connections held open, minus a baseline, divided by the connection count.
  Sampled fairly on both sides: the client first warms the accept path with a
  few throwaway connections held through both samples (so their cost cancels and
  first-touch JIT is not charged to the measured connections), the baseline is
  taken at a `warmed` marker before the measured batch opens, and both baseline
  and loaded figures are the _minimum_ of several samples (the live-set floor
  after a GC cycle, not a process caught mid-collection). This is OS-level RSS
  of the whole server, not a language-heap figure.

## Caveats

- **Per-connection memory is the binding's cost, and it is coarse.** It measures
  the Racket server process — the binding's per-connection state and a green
  thread per connection — which is what a Racket consumer actually pays, not the
  ~2 KB/connection the Zig core targets (see
  [`bench/peer_scaling_bench.zig`](../peer_scaling_bench.zig) for that figure).
  Read the per-connection figure as order-of-magnitude, not precise: at ~50
  connections a few-kB-per-connection signal sits inside a tens-of-MB process,
  so Racket's non-shrinking heap and GC-step granularity dominate. A suite whose
  latency/throughput phases allocate heavily (e.g. the capability-passing
  suites) pre-expands the server heap, so its connection delta reads lower than
  a light suite like `echo` whose heap first expands during the connection burst
  — an artifact of heap accounting, not of the connections themselves. Within a
  suite, both substrates start from a fresh, identically-warmed server, so the
  _backend-to-backend_ comparison is sound even where the absolute number is
  noisy.
- **Promise pipelining is deliberately not exercised.** Both substrates can
  invoke a returned promise before it resolves (Goblins natively, the pancake
  binding through `<-` on a promise, ADR-0007), but the registry suite resolves
  a capability and _then_ invokes it (two sequential round-trips) so both sides
  run the identical conversation shape. The benchmark rewards neither side's
  pipelining.
- **Driving is sequential.** One unit completes before the next begins, so the
  suite does not measure concurrent load. This keeps the comparison even across
  substrates.

## Layout

| File                                               | Role                                                                                          |
| -------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| [`metrics.rkt`](metrics.rkt)                       | percentiles, throughput math, `/proc` RSS — pure, substrate-blind                             |
| [`dispatch.rkt`](dispatch.rkt)                     | backend-blind method-table behavior builder                                                   |
| [`apps/`](apps/)                                   | the four shared applications (S0–S3)                                                          |
| [`backend-goblins.rkt`](backend-goblins.rkt)       | the five verbs over native Goblins + a TCP netlayer                                           |
| [`backend-pancake.rkt`](backend-pancake.rkt)       | the five verbs over the pancake Racket binding                                                |
| [`backend-pancake-tt.rkt`](backend-pancake-tt.rkt) | the pancake Racket binding with time-travel enabled (the third `bench-goblins` series)        |
| [`snapshot.rkt`](snapshot.rkt)                     | the Goblins half of the S5 snapshot/restore measurement (counterpart to `snapshot_bench.zig`) |
| [`server.rkt`](server.rkt)                         | server entrypoint: load app + backend, serve over TCP                                         |
| [`client.rkt`](client.rkt)                         | client entrypoint: run one measurement, print NDJSON                                          |
| [`bench.rkt`](bench.rkt)                           | orchestrator: spawn servers, drive clients, compare, report                                   |
| [`report.rkt`](report.rkt)                         | render the Markdown report (tables + Mermaid) and SVG bar charts                              |
| `*-test.rkt`                                       | unit/correctness tests (`metrics-test.rkt`, `apps-test.rkt`)                                  |

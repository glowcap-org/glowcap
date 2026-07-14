# Per-language consumer-cost benchmark

What does a consumer written in language X pay to run the same application over
the same pancake host and wire? This bench answers that, and only that. One
fixed reference host — the native Zig taskboard server — is held constant while
the client language is swapped: Deno, Python, Rust, the Racket binding, native
Zig, and Spritely Goblins as the reference CapTP peer.

Run it (the Zig host and Zig client are always built; other rows join when their
runtimes are on PATH):

```sh
zig build bench-langs                  # full run, every present client
zig build bench-langs -- --smoke       # tiny counts, fast sanity check
zig build bench-langs -- --client=zig  # one client
```

The orchestrator spawns a fresh host per client row, drives the taskboard
workload from that language's bench client, samples the client process's
resident set, times a cold start, and tears the host down. A comparison prints
to the terminal and artifacts land under `zig-out/bench-reports/`, each stamped
with the run's epoch second: a text report, a Markdown report with a value
table, and standalone SVG bar charts for latency, throughput, and cold start.

## This is not a language leaderboard

Each row measures a whole consumer stack — the runtime, that language's binding,
the application rewritten in it, and its garbage collector — sitting on one
pancake host. A faster row does not mean pancake's wire is faster in that
language. It means that whole stack was faster on this one machine on this one
day. Measure your own.

This is a different question from the substrate bench next door. `bench-goblins`
holds the language, runtime, and application source constant and swaps only the
substrate underneath, so its gap is the substrate's. This bench swaps the whole
client stack on purpose, because that stack is what a consumer actually pays.
The two benches stay separate; read
[`../goblins/README.md`](../goblins/README.md) for the substrate comparison.

## How it stays fair

Every row runs against the same ReleaseFast host binary, the same four-verb
workload (create, assign, complete, status, see [`contract.md`](contract.md)),
the same loopback TCP (the transport disables Nagle for every peer, so no row
eats a delayed-ACK stall the others dodge), and the same counts and driving
discipline: `latency` is sequential on every row, `throughput` is pipelined on
every row (ADR-0007 questioner-side, or Goblins' native pipelining for the
reference row), so no client gets an unfair fast path. A runtime with a JIT or a
garbage collector runs a warmup and
forces a collection before each measured window; an ahead-of-time runtime needs
neither. Each row's warmup is reported so a reader can see what hygiene it
received.

## The metrics

- **Latency** — one unit's round trips; p50, p99, p999, and mean in
  milliseconds. JIT or GC pauses inside the window stay in the number, because
  they are a real cost of that stack.
- **Throughput** — units back-to-back, in requests per second. Pipelined
  (ADR-0007): the four verbs ride one round trip, so this measures the consumer
  stack's steady-state rate when calls are addressed at answers, not awaited one
  at a time.
- **Session setup** — open many sessions and fetch the root on each; total
  and per-connection milliseconds.
- **Per-connection memory** — the client process's resident set with the
  connections held open, minus a baseline, divided by the connection count. It
  is OS-level resident set, not a binding-heap figure, so read it as an order of
  magnitude: a few kilobytes per connection sit inside a runtime heap many times
  larger. It is reproducible run-to-run, but it is **not comparable across
  runtime classes**: a garbage-collected runtime carrying a large pre-grown heap
  absorbs a few dozen connections' buffers without the resident set moving, so
  its figure understates the true per-connection cost — which is why the GC rows
  can report _fewer_ kilobytes per connection than the ahead-of-time Zig row
  that actually faults its buffers in. Compare a row to itself across changes,
  not to a row in a different runtime class.
- **Local turn** — the "push local actors into Zig?" cost question. Every
  binding dispatches a locally spawned actor in its own runtime today; if that
  dispatch were routed through the C host into a Zig vat instead, what would a
  local turn cost per binding? Each client spawns a counter actor two ways and
  runs sequential send→settle units against both: `in_lang` is the binding's
  own in-process dispatch (today's path), and `via_host` is the same behavior
  forced through the C host machinery across a loopback pair inside the
  client's own process. Both are reported in nanoseconds per turn (mean and
  p99) with their ratio. The `via_host` figure deliberately **over-counts** a
  real Zig-vat local turn: the loopback round trip pays the full wire codec in
  both directions, which an in-Zig local turn would skip, so read it as an
  upper bound, not a prediction. The Goblins reference row reports only its
  in-vat figure (there is no C host under Goblins), so its via-host cells
  render as `-`.
- **Cold start** — from process spawn to the first settled call. This is where
  ahead-of-time and interpreted or JIT runtimes genuinely diverge, so it is
  reported on its own and never folded into the steady-state numbers. The
  orchestrator precompiles each Racket client to bytecode first (Spritely
  Goblins already ships its collection precompiled), so the Racket rows measure
  real startup rather than Racket recompiling the binding from source on every
  spawn — without it the thin binding spuriously cold-started slower than all of
  Goblins.

## Caveats

The application is rewritten in each language, so its source is not
byte-identical; only its shape is held identical. The richer demo board keeps
the bindings behaviorally aligned through `zig build demo-tasks`, while this
bench keeps the shape aligned on a smaller app.

A runtime that is absent from the machine is skipped with a note, not treated as
a failure, the same posture the cross-language demos take. A smoke run with only
the Zig client present is still a valid run.

Goblins is the reference CapTP implementation in Racket, dialing the pancake
host as a peer. It is not Racket running pancake's binding, and the reports
label it apart from the language rows.

## Layout

| File                                   | Role                                                                            |
| -------------------------------------- | ------------------------------------------------------------------------------- |
| [`host.zig`](host.zig)                 | the fixed native Zig taskboard host                                             |
| [`orchestrator.zig`](orchestrator.zig) | native driver: spawn host, drive each client, sample `/proc`, render the report |
| [`contract.md`](contract.md)           | the NDJSON schema every client implements                                       |
| [`clients/`](clients/)                 | one bench client per language                                                   |

The orchestrator is native Zig, so the driving and reporting path needs no
Racket: the Zig host and Zig client run with only the Zig toolchain installed.
Racket joins only as two of the client rows — the binding row and the Goblins
reference — each skipped with a note when its runtime is absent.

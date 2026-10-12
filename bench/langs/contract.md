# bench-langs client contract

Every per-language bench client speaks the same contract, so the orchestrator
(`orchestrator.zig`) drives them uniformly. This file is the schema that the
orchestrator and each client implement.

## Invocation

```
<client-command...> <mode> <host> <port> <n>
```

- `mode` is one of `latency`, `throughput`, `connections`, `cold`, `local`.
- `host` is the loopback address (`127.0.0.1`).
- `port` is the host's listening port (the orchestrator learns it from the
  host's readiness line). `local` is self-contained: the orchestrator spawns no
  host and passes port 0, and the client may ignore host and port.
- `n` is the unit count (latency/throughput/local) or connection count
  (`connections`). Ignored by `cold`.

A client reads no other configuration. It runs the requested mode (connecting
to the host, except in `local` mode where the work stays in its own process),
prints one NDJSON line to stdout, and exits 0.

## The unit

One bench unit is the taskboard four-verb script:

1. `create` on the board root, which returns a fresh task capability.
2. `assign` on that task.
3. `complete` on that task.
4. `status` on that task, which must settle to the bytes `done`.

The `latency` and `throughput` modes run the same four verbs two ways:

- `latency` runs them **sequentially**: each send is settled before the next is
  issued, so the figure is four serial round trips, the cost of a dependent
  chain when the consumer awaits each step.
- `throughput` runs them **pipelined** (ADR-0007, the questioner half): `assign`,
  `complete`, and `status` are addressed at the *answer* `create` will resolve to
  so the whole unit costs one round trip. `assign` and `complete` are one-way.
  Only the final `status` allocates an answer and is settled. Each binding
  uses its own questioner surface (a vow/promise returned by a send is itself a
  send target). The Goblins-reference row uses Goblins' promise pipelining, so
  the workload is identical across rows.

In both modes a client asserts that the final status equals the bytes `done`
and fails otherwise.

## NDJSON output

The host announces readiness:

```json
{ "v": 1, "event": "ready", "listen": "127.0.0.1:<port>" }
```

Each client mode prints one line. `client` is the language label. `runtime`
names the concrete runtime and version where the client can determine it.

- `latency`: run `n` units on one connection. Report the distribution in
  milliseconds.

```json
{"v":1,"metric":"latency","client":"<name>","suite":"taskboard","n":<n>,"p50_ms":<f>,"p99_ms":<f>,"p999_ms":<f>,"mean_ms":<f>,"runtime":"<label>","warmup_n":<int>}
```

- `throughput`: run `n` units back-to-back on one connection. Report the rate.

```json
{"v":1,"metric":"throughput","client":"<name>","suite":"taskboard","n":<n>,"total_ms":<f>,"rps":<f>,"runtime":"<label>","warmup_n":<int>}
```

- `connections`: open a few throwaway warmup connections, print the `warmed`
  marker (the orchestrator samples the baseline resident set here), then open
  `n` measured connections and print the `connections` line while holding them
  open for the orchestrator's loaded sample. Each connection owns a fresh
  client runtime/Host identity, because a single Host refuses a second live
  session to the same peer. The measured unit is the complete consumer-side
  runtime plus its one connection.

```json
{"v":1,"event":"warmed"}
{"v":1,"metric":"connections","client":"<name>","suite":"taskboard","conns":<n>,"total_ms":<f>,"per_conn_ms":<f>,"runtime":"<label>"}
```

- `cold`: connect, fetch the root, run one unit, then print the `cold-done`
  marker and exit. The orchestrator times spawn to this marker, so the client
  prints nothing else first.

```json
{ "v": 1, "event": "cold-done", "client": "<name>" }
```

- `local`: the local-turn instrument. The unit is not the taskboard
  script but one send→settle against a local counter actor whose behavior
  answers the verb `hit` by incrementing a count and returning it. The client
  runs `n` such units **sequentially** (each settled before the next) on two
  paths and reports both in nanoseconds per turn (mean and p99):

  - `in_lang`: the counter is spawned the binding's idiomatic way
    (`conn.spawn`, the Zig vat near path for the Zig client, a Goblins
    actor in one vat for the reference row), so a send dispatches in process.
    This is what local actor dispatch costs each consumer stack.
  - `via_host`: the same behavior forced through the C host machinery: the
    client builds a loopback pair inside its own process (listen on
    `127.0.0.1:0` and connect to itself), publishes the counter on the
    accepting side, fetches it from the dialing side, and runs the units
    across that pair. Every turn pays wire codec, feed, trampoline, and
    marshal in both directions.

  After each path the client asserts the final count equals warmup + `n` and
  fails otherwise. The `goblins-ref` client reports only `in_lang`. Its
  `via_host_ns`, `via_host_p99_ns`, and `ratio` fields are JSON `null`.

```json
{"v":1,"metric":"local","client":"<name>","suite":"local-turn","n":<n>,"in_lang_ns":<f>,"in_lang_p99_ns":<f>,"via_host_ns":<f|null>,"via_host_p99_ns":<f|null>,"ratio":<f|null>,"runtime":"<label>","warmup_n":<int>}
```

  `ratio` is `via_host_ns / in_lang_ns`. `in_lang` is the binding dispatching a
  local actor in its own runtime. `via_host` is the loopback route through the
  C host, which includes a loopback round trip and two wire-codec passes. The
  mode answers what the C host path costs per binding. It does not measure the
  wire alone.

## Warmup and GC hygiene

Latency, throughput, and local windows target steady state. A runtime with a
JIT or a garbage collector (Deno, Python, the Racket binding, Goblins) runs
`min(n, 500)` warmup units and forces a collection before opening the measured
window (in `local` mode, on each of the two paths separately), as
`bench/goblins/client.rkt` does. Ahead-of-time rows (Zig, Rust) report
`warmup_n` of 0. Per-operation GC inside the window stays in the number, as a
cost of that consumer stack.

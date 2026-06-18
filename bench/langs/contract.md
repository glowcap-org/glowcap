# bench-langs client contract

Every per-language bench client speaks the same small contract so the
orchestrator (`orchestrator.zig`) can drive them uniformly. This file is the
schema; the orchestrator and each client implement it.

## Invocation

```
<client-command...> <mode> <host> <port> <n>
```

- `mode` is one of `latency`, `throughput`, `connections`, `cold`.
- `host` is the loopback address (`127.0.0.1`).
- `port` is the host's listening port (the orchestrator learns it from the
  host's readiness line).
- `n` is the unit count (latency/throughput) or connection count
  (`connections`); ignored by `cold`.

A client reads no other configuration. It connects, runs the requested mode,
prints one NDJSON line to stdout, and exits 0.

## The unit

One bench unit is the taskboard four-verb script:

1. `create` on the board root, which returns a fresh task capability.
2. `assign` on that task.
3. `complete` on that task.
4. `status` on that task, which must settle to the bytes `done`.

The `latency` and `throughput` modes run the same four verbs two ways:

- `latency` runs them **sequentially**: each send is settled before the next is
  issued, so the figure is four serial round trips — the cost of a dependent
  chain when the consumer awaits each step.
- `throughput` runs them **pipelined** (ADR-0007, the questioner half): `assign`,
  `complete`, and `status` are addressed at the *answer* `create` will resolve to
  — sent without awaiting it — so the whole unit costs one round trip and only the
  final `status` is settled. Each binding expresses this with its own questioner
  surface (a vow/promise returned by a send is itself a send target); the
  Goblins-reference row uses Goblins' native promise pipelining, so the workload
  stays identical across rows.

Either way a client asserts the final status equals the bytes `done` and fails
loudly otherwise.

## NDJSON output

The host announces readiness:

```json
{ "v": 1, "event": "ready", "listen": "127.0.0.1:<port>" }
```

Each client mode prints one line. `client` is the language label; `runtime`
names the concrete runtime and version where the client can determine it.

- `latency`: run `n` units on one connection; report the distribution in
  milliseconds.

```json
{"v":1,"metric":"latency","client":"<name>","suite":"taskboard","n":<n>,"p50_ms":<f>,"p99_ms":<f>,"p999_ms":<f>,"mean_ms":<f>,"runtime":"<label>","warmup_n":<int>}
```

- `throughput`: run `n` units back-to-back on one connection; report the rate.

```json
{"v":1,"metric":"throughput","client":"<name>","suite":"taskboard","n":<n>,"total_ms":<f>,"rps":<f>,"runtime":"<label>","warmup_n":<int>}
```

- `connections`: open a few throwaway warmup connections, print the `warmed`
  marker (the orchestrator samples the baseline resident set here), then open
  `n` measured connections and print the `connections` line while holding them
  open for the orchestrator's loaded sample.

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

## Warmup and GC hygiene

Latency and throughput windows reflect steady state. A runtime with a JIT or a
garbage collector (Deno, Python, the Racket binding, Goblins) runs `min(n, 500)`
warmup units and forces a collection before opening the measured window, the
same hygiene `bench/goblins/client.rkt` applies. Ahead-of-time runtimes (Zig,
Rust) need no warmup and report `warmup_n` of 0. Per-operation GC inside the
window is left in the number: it is a real cost of that consumer stack.

---
type: static
description: What the Goblins, glowcap and glowcap-with-time-travel benchmarks hold constant and what they cannot.
sources:
  - resource: /bench/goblins/
---

# Benchmark methodology

The Goblins, glowcap, and glowcap-with-time-travel series share an application
and conversation shape. The harness holds some things constant and cannot hold
others, and the sections below list both.

## Shared application

The four applications in `apps/` import neither substrate. `dispatch.rkt`
builds their method tables. Each backend provides the same five operations:
run a server, connect a client, fetch a capability, call it, and close.

When an application returns a new capability, Goblins uses `spawn`. glowcap
uses `session-spawn` to export it. That difference belongs to each substrate.

One measured unit is one synchronous send-and-settle cycle. glowcap pumps its
sans-I/O peer through `session-send`. Goblins awaits an eventual send on its
vat. The Goblins driver reuses its settlement channel, so the harness adds no
per-call allocation on only one side.

Both backends use loopback TCP in separate processes through Racket's default
socket settings. Neither changes Nagle or buffer options.

## Warmup and collection

Each measured phase warms up with as many as 500 units. This keeps initial JIT
compilation and heap growth out of the sample window.

The harness then requests a full collection before timing. Collections caused
by measured operations stay inside the window, as part of the runtime cost.

## Connection memory

The client opens a few throwaway connections before the baseline sample and
keeps them open through the loaded sample. This warms the accept path on both
backends.

Memory is Linux `VmRSS` for the whole server process. The baseline and loaded
values are each the minimum of several samples, then the difference is divided
by the measured connection count. Taking the minimum reduces the chance of
sampling during a collection. RSS is still not a language-heap measurement.

At the default scale, a few kilobytes per connection are measured inside a
process tens of megabytes large. Racket's heap growth and GC granularity can
dominate the delta. A suite that expanded the heap during earlier phases may
therefore show a smaller connection delta than a lighter suite. Compare
backends within one suite. Do not compare absolute memory numbers across
suites as though they were allocations.

## Limits

- The benchmark includes the Racket binding and runtime on the glowcap side.
  It does not measure glowcap's Zig actor runtime.
- Calls are sequential, so the benchmark does not model concurrency or
  saturation.
- The registry waits for the returned capability before calling it, so neither
  backend gets credit for promise pipelining.
- Loopback removes field latency, loss, and routing.
- The snapshot sweep measures scaling behavior. Source inspection and tests,
  not timing alone, establish whether state bytes are shared.

Because of these limits, a generated report describes one dated machine run.

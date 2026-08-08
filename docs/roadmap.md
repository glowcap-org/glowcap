# Remaining work

This page lists unfinished work only. [What ships](shipped.md) covers the
present, [known limitations](boundaries.md) covers their consequences, and
[the ladder](ladder.md) tracks progress toward 1.0. Open OCapN and Goblins
questions are [watched separately](upstream-watch.md).

## Platforms and reachability

- **Windows and IOCP.** There is no Windows runtime check or IOCP backend.
  Windows support needs the backend behind the existing completion-loop
  contract, which is total (`validateBackend`), then live tests and release
  artifacts.
- **macOS runtime CI.** The kqueue path is cross-compiled on every push but
  never executed. A macOS runner closes this gap.
- **Cold-dialing browsers across relays.** Browser-to-browser and
  native-to-browser cold dial both work through one shared relay, and the
  rendezvous dial is implemented in every consumer
  (`zig build bindings-keyed-relay-rendezvous`). A cross-relay
  dial needs locators that carry a usable route as well as the peer identity
  ([ADR-0088](decisions/adr/ADR-0088-fully-functioning-browser-peer.md)).

## Scale and release

- **A live 500,000-session measurement.** The core and host have checked memory
  budgets, and the TCP and iroh loops serve many connections. The target is not
  achieved until a live run at that scale records its machine, command, memory,
  and result in [the ladder](ladder.md).
- **Published C archives.** `zig build release-pack` and the release workflow
  exist, but no versioned assets are live. Publication requires green packages
  for every target, the `releases_published` switch in
  [`bindings/c-abi-resolve.json`](../bindings/c-abi-resolve.json), and a
  cold-cache smoke against the real release URL. The full checklist is in the
  [packaging guide](../bindings/PACKAGING.md#publishing-c-archives-flip-checklist).

## Beyond the library

The ocapnviz protocol viewer and the A2A agent-to-agent facade are products
built on pancake. Neither adds wire semantics. The A2A design sketch is in
[`docs/planning/`](planning/), deferred by
[ADR-0084](decisions/adr/ADR-0084-pancake-cli-product-boundary.md).

`pancake griddle run` ships the deterministic simulator: a seeded schedule,
an NDJSON timeline, per-link latency, and partition. The viewer at
`apps/ocapnviz/` imports that timeline; the live producer is native. The host
core's trace tap is the one place that reports session opens, message verbs,
and closes. Every binding's `enable_trace` stamps and forwards those events.
An embedder that can take a callback uses `pancake_host_set_trace`; a browser
drains the same facts from the ring `pancake_host_set_trace_queue` installs.
The rooms server serves the stream at `ROOMS_VIZ_PORT` for Live mode, and
other peers publish there too, so a direct message the room never carries
still reaches the timeline (ADR-0104).

Three pieces of that family are named and unbuilt.

**OpenTelemetry export** is an adapter-only OTLP exporter off the same Host and
session event spine the stderr logs already use. It is enabled by `OTEL_*` or a
flag, off by default, and never in a `core = true` module. The timeline schema
stays the source of truth either way, because topology and deterministic replay
are not recoverable from generic spans.

**The object layer** is the set of facts the tap does not report: what a
session carries, rather than which sessions exist.

**A capability-native trace stream** would replace the ambient loopback port
that serves the feed today.

The second and third are argued in
[ADR-0106](decisions/adr/ADR-0106-viz-control-capability.md), whose Scope
section says plainly that none of the three is implemented.

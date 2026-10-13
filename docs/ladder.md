# The route to 1.0

glowcap has five milestones on the way to 1.0. Their order matters: protocol
behavior comes before performance work, and the public APIs come before adding
more ways to reach a peer.

| Milestone | Standing |
| --- | --- |
| 1. Protocol conformance | In progress. Live Goblins over testing TCP, and the upstream suite, cover the main conversation and handoff paths. Several edge cases still lack outside-peer evidence. |
| 2. Performance at scale | Met. Memory and latency budgets run on main and dev pushes and pull requests. A release-mode run held 500,000 signed sessions live over loopback TCP. |
| 3. Hosted applications | Met. Native and cross-language applications exercise the public API. |
| 4. C ABI and bindings | Met. All four bindings dial Goblins and are dialed by it through the C ABI. |
| 5. Transport reachability | In progress. The first-party provider seams, routed browser cold dial, and recurring macOS runtime suite ship. Windows support and a deployed public-certificate relay proof remain. |

[The vision](vision.md) defines the destination. [What ships](shipped.md) is
the current inventory, and the [roadmap](roadmap.md) lists the unfinished work.

## What protects every milestone

The protocol core is split into one-way Zig modules. The build rejects a codec
that imports another codec, protocol code that reaches into an adapter, or
portable code that imports `std.Io` or platform calls
([ADR-0040](decisions/adr/ADR-0040-layer-modules-as-import-law.md)).

## 1. Protocol conformance

glowcap checks its protocol behavior three ways:

- the upstream OCapN suite runs against the production host
- live Spritely Goblins peers call glowcap and accept calls from it,
  recurring over testing TCP
- in-tree scenarios cover message arms, failure paths, limits, and both codecs

The live checks cover calls, promises, sturdyrefs, garbage collection in both
directions, answer release, and all three roles in a three-party handoff.
Each language binding also acts as a Goblins client, recipient, and gifter,
and proves remote object reclamation before its session closes.

This milestone remains open because some implemented behavior has only in-tree
or on-demand evidence. [Community review](community-review.md) has the exact
matrix.

## 2. Performance at scale

The target is 500,000 live sessions on one node.

The build checks these session and Host costs. Host-wide rows say so
explicitly:

| Cost | Checked limit |
| --- | --- |
| `engine.Peer` inline state | at most 1176 bytes |
| Warm protocol state | at most 2 KiB |
| Completion-loop slot beyond its embedded peer | exactly 144 bytes |
| Completion-backed keyed-relay adapter state | exactly 272 bytes per relay leg |
| iroh completion-adapter row | exactly 64 bytes per loop connection |
| WebRTC completion-adapter row | exactly 104 bytes per open DataChannel |
| Completion-resident connection row (stream wires on HostRuntime) | exactly 152 bytes per connection, holding no buffer while idle |
| Host session shell | at most 528 bytes, including indexed listeners for cancellable bulk failure |
| Shared enliven index | 24 bytes per Host. Sessions gain none |
| Turn failure notifications | 40 bytes per Host plus 16-byte answer slots, retaining at most 4 KiB after a turn |
| Host session locator identity | one owned transport/designator block per session |
| Warm local Vat queue batch | zero general-purpose allocations |
| Retained queue spare in the Host-owned Vat | one chunk per Host: its row array within one 4 KiB list page plus a small header, its payload arena at most 4 KiB |
| Steady delivery to a live export | one owned-frame allocation |

These are Debug and ReleaseSafe sizes. ReleaseFast and ReleaseSmall drop a
one-word lock from each standard-library list or map header, so they measure a
word less per container.

A busy connection can also hold two 16 KiB outbound buffers, which matters more
than protocol state when sizing a loaded server. An idle connection holds
neither, and no read buffer.

ReleaseFast checks also keep a warm inbound turn below 2,000 ns, an answered
outbound send below 8,000 ns, and garbage-collection work from growing faster
than 3× when the answer count grows from 1,000 to 8,000. These are regression
limits, not portable benchmark results.

`zig build bench-peer-scaling -- --live` measures real loopback sockets at
increasing connection counts. The server and load generator are separate
processes with 32 shards each. Each server shard is a `HostRuntime` serving TCP
through a completion resident
([ADR-0202](decisions/adr/ADR-0202-stream-transports-join-hostruntime-as-a-completion-resident.md)).
Every client signs its own session and fetches a published capability before
the barrier opens, and all sessions stay open while RSS is sampled.

On 2026-10-13, a ReleaseFast run reached 500,000 sessions on Linux
7.0.0-1019-nvidia, aarch64, 20 logical CPUs, 121.7 GiB RAM, and 15 GiB swap,
on the io_uring backend. The epoll fallback has no equivalent full-target
measurement. The server grew from 11,816 KiB to 3,816,584 KiB RSS:
3,804,768 KiB (3.63 GiB) incremental, about 7.6 KiB per session. The
separate load process used 2,890,300 KiB (2.76 GiB). The signed-handshake
and bootstrap-fetch barrier completed in 18.453 seconds, or 36.9 microseconds
per session when amortized across the run. The figure is a same-machine
capacity measurement, not WAN latency.

The connections are plain TCP, so each handshake is signed but the bytes are
not encrypted. The command below runs in its own user and network namespace,
which carries no connection-tracking rules, so the host's tracking table does
not bind the run. It also raises the descriptor limit both processes need,
which the bench does not raise itself.

```sh
unshare -Urn sh -eu -c '
ulimit -n 524288
ip link set lo up
exec zig build -Doptimize=ReleaseFast bench-peer-scaling -- --live --live-max=500000
'
```

## 3. Hosted applications

The accountability application records who invoked a hosted capability and
attributes an introduced call to the recipient, not the introducer. The rooms,
tasks, and tools applications run one session API from Zig, Rust, TypeScript,
Python, and Racket, covering setup, hosting, calls, promises, capability
passing, and handoff as an application uses them.

## 4. C ABI and bindings

The C headers are generated from Zig and checked for drift. Rust, TypeScript,
Python, and Racket consume the same ABI and archives through generated function
tables and checked layout mirrors. Each binding runs an ordinary glowcap
conversation and a live Goblins conversation through that ABI.

Those checks cover the shared session API, both application-facing handoff
roles, and both session directions. In the reciprocal listener matrix, a real
Goblins vat dials each binding, enlivens its Host-wide actor, and reads the
actor's exact reply.

## 5. Transport reachability

glowcap supports plain TCP, keyed TCP, noise TCP, noise relay, keyed relay,
in-process pipes, iroh, WebRTC, and onion. In recurring CI, a native peer
cold-dials a Chromium-hosted actor over local WSS with end-to-end Noise, and
every native binding follows a locator-carried relay route. macOS runs the
native test suite. The external-runtime matrix runs on Linux.

Remaining work:

- extend native Session/Server setup to multiplexed providers and complete
  managed WebRTC setup across the native fronts
- add a Windows completion backend
- repeat the native-to-browser relay proof at a deployed hostname with a
  public certificate

[Known limitations](boundaries.md) explains the consequences today. The
[roadmap](roadmap.md) lists the work needed to close them.

# The route to 1.0

glowcap has five milestones on the way to 1.0. Their order matters: protocol
behavior comes before performance work, and the public APIs come before adding
more ways to reach a peer.

| Milestone | Standing |
| --- | --- |
| 1. Protocol conformance | In progress. Live Goblins over testing TCP, and the upstream suite, cover the main conversation and handoff paths; several edge cases still lack outside-peer evidence. |
| 2. Performance at scale | Met. Memory and latency budgets run on main and dev pushes and pull requests; a release-mode run held 500,000 authenticated socket sessions live. |
| 3. Hosted applications | Met. Native and cross-language applications exercise the public API. |
| 4. C ABI and bindings | Met. All four bindings dial Goblins and are dialed by it through the C ABI. |
| 5. Transport reachability | In progress. The first-party provider seams, routed browser cold dial, and recurring macOS runtime suite ship; Windows support and a deployed public-certificate relay proof remain. |

[The vision](vision.md) defines the destination. [What ships](shipped.md) is
the current inventory, and the [roadmap](roadmap.md) lists the unfinished work.

## What protects every milestone

The protocol core is split into one-way Zig modules. The build rejects a codec
that imports another codec, protocol code that reaches into an adapter, or
portable code that imports `std.Io` or platform calls. These checks make the
architecture a property of the build rather than a convention
([ADR-0040](decisions/adr/ADR-0040-layer-modules-as-import-law.md)).

## 1. Protocol conformance

glowcap checks its protocol behavior three ways:

- the upstream OCapN suite runs against the production host;
- live Spritely Goblins peers call glowcap and accept calls from it,
  recurring over testing TCP;
- in-tree scenarios cover message arms, failure paths, limits, and both codecs.

The live checks cover calls, promises, sturdyrefs, inbound export release, and
all three roles in a three-party handoff. Outbound garbage collection and
answer release have in-tree coverage. Each language binding also acts as a
Goblins client, recipient, and gifter.

This milestone remains open because some implemented behavior has only in-tree
or on-demand evidence. [Community review](community-review.md) has the exact
matrix.

## 2. Performance at scale

This milestone is met. The target is 500,000 live sessions on one node.

The build checks these session and Host costs; Host-wide rows say so
explicitly:

| Cost | Checked limit |
| --- | --- |
| `engine.Peer` inline state | at most 1176 bytes |
| Warm protocol state | at most 2 KiB |
| Completion-loop slot beyond its embedded peer | exactly 144 bytes |
| Completion-backed keyed-relay adapter state | exactly 272 bytes per relay leg |
| Sealing completion-adapter state (`noise-relay`) | exactly 952 bytes per sealed leg, on top of the leg it wraps |
| Host session shell | at most 528 bytes |
| Host session locator identity | one owned transport/designator block per session |
| Warm local Vat queue batch | zero general-purpose allocations |
| Retained queue spare in the Host-owned Vat | one 4,152-byte chunk per Host with at most 4 KiB of payload arena |
| Steady delivery to a live export | one owned-frame allocation |

These are Debug and ReleaseSafe measurements: Debug is where the checks run,
and ReleaseSafe is what `release-pack` asks for. In those modes every embedded standard-library list or
map header carries a one-word pointer-stability lock that ReleaseFast and
ReleaseSmall drop, so a fast build measures a word less per container.

A busy connection can also retain two 16 KiB outbound buffers. That 32 KiB
ceiling is much larger than the protocol state, so it matters more when sizing
a loaded server. Idle connections do not retain those buffers or a dedicated
read buffer.

ReleaseFast checks also keep a warm inbound turn below 2,000 ns, an answered
outbound send below 8,000 ns, and garbage-collection work from growing faster
than 3× when the answer count grows from 1,000 to 8,000. These are regression
limits, not portable benchmark results.

`zig build bench-peer-scaling -- --live` measures real loopback sockets at
increasing connection counts. Its server and load generator are separate
processes, each with 32 completion-loop shards and no connection-owned thread.
Every client has a unique signed session identity and must fetch the server's
published capability before the barrier opens; all sessions remain open while
RSS is sampled.

On 2026-08-24, a ReleaseFast run reached 500,000 sessions on Linux
6.17.0-1029-nvidia, aarch64, 20 logical CPUs, 121.7 GiB RAM, and 16 GiB swap.
The server grew from 573,828 KiB to 4,548,376 KiB RSS: 3,974,548 KiB
(3.79 GiB) incremental. The separate load process used 3,015,316 KiB
(2.88 GiB). The signed-handshake and bootstrap-fetch barrier completed in
15.720 seconds, or 31.4 microseconds per session when amortized across the run.
The figure is a same-machine capacity measurement, not WAN latency.

The host's connection-tracking table was capped below the target, so the run
used an isolated user/network namespace and exempted its loopback traffic from
connection tracking. The benchmark itself spreads the clients over 32
listeners so one ephemeral-port range is not mistaken for session capacity:

```sh
unshare -Urn sh -eu -c '
ip link set lo up
nft add table inet glowcap_scale
nft "add chain inet glowcap_scale prerouting { type filter hook prerouting priority raw; policy accept; }"
nft "add chain inet glowcap_scale output { type filter hook output priority raw; policy accept; }"
nft add rule inet glowcap_scale prerouting iifname lo notrack
nft add rule inet glowcap_scale output oifname lo notrack
exec zig build -Doptimize=ReleaseFast bench-peer-scaling -- --live --live-max=500000
'
```

## 3. Hosted applications

This milestone is met.

The accountability application hosts a capability over a real TCP session,
records who invoked it, and proves across three owning Hosts that an introduced
capability attributes the recipient rather than the introducer. The rooms,
tasks, and tools applications run the same
session API from Zig, Rust, TypeScript, Python, and Racket. Together they cover
connection setup, hosting, calls, promises, capability passing, and handoff at
the level an application uses them.

## 4. C ABI and bindings

This milestone is met.

The C headers are generated from Zig and checked for drift. Rust, TypeScript,
Python, and Racket consume the same ABI and archives through generated function
tables and checked layout mirrors. Each binding runs an ordinary glowcap
conversation and a live Goblins conversation through that ABI.

Those checks cover the shared session API, both application-facing handoff
roles, and both session directions. In the reciprocal listener matrix, a real
Goblins vat dials each binding, enlivens its Host-wide actor, and reads the
actor's exact reply.

## 5. Transport reachability

The transport contract supports plain TCP, keyed TCP, noise TCP and noise
relay (ADR-0107's sealed channel), keyed relay, in-process pipes, iroh,
WebRTC, and onion (the standardized Tor netlayer). TCP, iroh, WebRTC, and
outbound keyed-relay have Host completion-loop integrations. The WebRTC path
adopts signaled peers through a completion backend
(`zig build webrtc-loop`). Native three-party redeem over a bare `webrtc`
give is proved by `zig build webrtc-bridge-redeem`.

The remaining work is about deployment evidence and operating systems rather
than another protocol core. A native peer cold-dials a Chromium-hosted actor
over local WSS and end-to-end Noise in recurring CI, and every native
binding follows a locator-carried rendezvous route. The recurring macOS job
executes the native test suite, while the full external-runtime matrix remains
on Linux.

- add a Windows completion backend;
- repeat the native-to-browser relay proof at a deployed hostname with a
  public certificate;

[Known limitations](boundaries.md) explains the consequences today. The
[roadmap](roadmap.md) lists the work needed to close them.

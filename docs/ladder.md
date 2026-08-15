# The route to 1.0

pancake has five milestones on the way to 1.0. Their order matters: protocol
behavior comes before performance work, and the public APIs come before adding
more ways to reach a peer.

| Milestone | Standing |
| --- | --- |
| 1. Protocol conformance | In progress. Live Goblins and upstream-suite checks cover the main conversation and handoff paths; several edge cases still lack outside-peer evidence. |
| 2. Performance at scale | In progress. Memory and latency budgets run on every push; 500,000 live socket sessions have not been measured. |
| 3. Hosted applications | Met. Native and cross-language applications exercise the public API. |
| 4. C ABI and bindings | Met. Four bindings consume the generated C ABI and talk to Goblins. |
| 5. Transport reachability | In progress. The first-party provider seams and routed relay cold dial ship; Windows support and macOS runtime evidence remain. |

[The vision](vision.md) defines the destination. [What ships](shipped.md) is
the current inventory, and the [roadmap](roadmap.md) lists the unfinished work.

## What protects every milestone

The protocol core is split into one-way Zig modules. The build rejects a codec
that imports another codec, protocol code that reaches into an adapter, or
portable code that imports `std.Io` or platform calls. These checks make the
architecture a property of the build rather than a convention
([ADR-0040](decisions/adr/ADR-0040-layer-modules-as-import-law.md)).

## 1. Protocol conformance

pancake checks its protocol behavior three ways:

- the upstream OCapN suite runs against the production host;
- live Spritely Goblins peers call pancake and accept calls from it;
- in-tree scenarios cover message arms, failure paths, limits, and both codecs.

The live checks cover calls, promises, sturdyrefs, inbound export release, and
all three roles in a three-party handoff. Outbound garbage collection and
answer release have in-tree coverage. Each language binding also acts as a
Goblins client, recipient, and gifter.

This milestone remains open because some implemented behavior has only in-tree
or on-demand evidence. Goblins-written `op:get` / `op:index` frames reach
pancake's projection responders, and the Goblins-side netlayer probe observes
pancake fulfilling both projected answers with the expected payloads. Live
Goblins-over-iroh covers sessions both ways (`goblins-iroh`) and one
exporter-role rooms handoff (`goblins-rooms-dm-iroh`); the other two handoff
roles stay TCP-only. Null and live `op:untag` also wait on upstream support.
[Community review](community-review.md) has the exact matrix.

## 2. Performance at scale

The goal is 500,000 live sessions on one node. That is a target, not a current
claim.

The build checks these session and Host costs; Host-wide rows say so
explicitly:

| Cost | Checked limit |
| --- | --- |
| `engine.Peer` inline state | at most 1136 bytes |
| Warm protocol state | at most 2 KiB |
| Completion-loop slot beyond its embedded peer | exactly 128 bytes |
| Completion-backed keyed-relay adapter state | exactly 264 bytes per relay leg |
| Sealing completion-adapter state (`noise-relay`) | exactly 936 bytes per sealed leg, on top of the leg it wraps |
| Host session shell | at most 528 bytes |
| Host session locator identity | one owned transport/designator block per session |
| Warm local Vat queue batch | zero general-purpose allocations |
| Retained queue spare in the Host-owned Vat | one 4,152-byte chunk per Host with at most 4 KiB of payload arena |
| Steady delivery to a live export | one owned-frame allocation |

A busy connection can also retain two 16 KiB outbound buffers. That 32 KiB
ceiling is much larger than the protocol state, so it matters more when sizing
a loaded server. Idle connections do not retain those buffers or a dedicated
read buffer.

ReleaseFast checks also keep a warm inbound turn below 2,000 ns, an answered
outbound send below 8,000 ns, and garbage-collection work from growing faster
than 3× when the answer count grows from 1,000 to 8,000. These are regression
limits, not portable benchmark results.

`zig build bench-peer-scaling -- --live` measures real loopback sockets at
increasing connection counts. The milestone remains open until a run reaches
500,000 and records its machine, command, memory, and timing here.

## 3. Hosted applications

This milestone is met.

The accountability application hosts a capability over a real TCP session and
records who invoked it. The rooms, tasks, and tools applications run the same
session API from Zig, Rust, TypeScript, Python, and Racket. Together they cover
connection setup, hosting, calls, promises, capability passing, and handoff at
the level an application uses them.

## 4. C ABI and bindings

This milestone is met.

The C headers are generated from Zig and checked for drift. Rust, TypeScript,
Python, and Racket consume the same ABI and archives through generated function
tables and checked layout mirrors. Each binding runs an ordinary pancake
conversation and a live Goblins conversation through that ABI.

Those checks cover the shared session API and both application-facing handoff
roles. They do not make every binding equally exercised as a listener:
Goblins currently dials only the TypeScript binding in CI.

## 5. Transport reachability

The transport contract supports plain TCP, keyed TCP, noise TCP and noise
relay (ADR-0107's sealed channel), keyed relay, in-process pipes, iroh,
WebRTC, and onion (the standardized Tor netlayer). TCP, iroh, WebRTC, and
outbound keyed-relay have Host completion-loop integrations. The WebRTC path
adopts signaled peers through a completion backend
(`zig build webrtc-loop`). Native three-party redeem over a bare `webrtc`
give is proved by `zig build webrtc-bridge-redeem`.

The remaining work is about reach and operating systems rather than another
protocol core:

- run the macOS backend instead of only compiling it;
- add a Windows completion backend;
- let native peers find browsers and let browsers cross relay boundaries;
- complete the live 500,000-session measurement.

[Known limitations](boundaries.md) explains the consequences today. The
[roadmap](roadmap.md) owns the work needed to close them.

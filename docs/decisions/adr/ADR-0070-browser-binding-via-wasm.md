---
id: ADR-0070
status: accepted
date: 2026-07-08
tags: [bindings, transport, wasm, browser]
decision: "A browser peer is the sans-io core compiled to WebAssembly behind the existing binding API, with a browser transport added in two steps: WebSocket, then WebRTC DataChannel."
supersedes: []
superseded_by: []
---

# ADR-0070 Browser binding via WebAssembly

> **Current standing.** The WebAssembly Host, WebSocket channel, browser and
> native WebRTC DataChannel arms, and capability-carried signaling scenarios
> have landed. ADR-0072 and ADR-0079 replaced the `Peer` / `Node` binding names
> below with `Host` / `Session`. ADR-0089 supplies Milestone 2's transport, but
> generic Host adoption and three-party redemption over that transport remain
> open. Signaling through a capability is one prerequisite for redemption; it
> is not itself a completed handoff.

## Context

A browser cannot open a raw TCP socket or speak iroh's QUIC, so today a browser
tab is not an OCapN peer at all. The rooms web demo works around this with a
per-tab bridge (`apps/rooms/web/serve.ts`): the browser talks JSON over a
WebSocket to a Deno process that holds the real pancake connection through the C
ABI and relays between the two. The bridge is honest about what it is, but the
browser never holds a capability, never runs the session, and cannot be
introduced to another browser directly. That is a gap in reach, not in the
protocol.

The gap is closable because of a decision the substrate already made: the core
is sans-io. `src/ocapn/{model,codec,session,engine}` are deterministic, no-I/O
Zig that turn frames into events and messages into frames and nothing else, and
`zig build cross-check` already compiles that core for `wasm32`. This engages
the [core-boundary First Principle](../../../AGENTS.md#first-principles): the
same property that keeps sockets and schedulers out of the core is what lets the
core run in a browser sandbox unchanged.

## Decision

A browser binding is the sans-io core compiled to WebAssembly, exposed through
the **same** `Peer`/`Context`/`Node` API the other bindings present. The
TypeScript binding is already layered for this: `bindings/ts/stack/mod.ts` sits
on an FFI seam (`bindings/ts/stack/internal/ffi/runtime.ts`, today `Deno.dlopen`
against `libpancake_ocapn`). A browser binding replaces that one seam with a
WebAssembly instance: instantiate `pancake_ocapn.wasm`, call its exports, and
marshal frames across the WASM/JS boundary as `ptr + len` the same way the C ABI
already does: leaving the public API shape intact.

What the browser still lacks is a transport, added in two milestones:

- **Milestone 1. WebSocket.** The browser holds a real peer and moves OCapN
  frames over a WebSocket to a peer that accepts WebSocket connections. This
  makes the browser a first-class OCapN peer and retires the per-tab bridge: the
  rooms `serve.ts` becomes a static file server plus a WebSocket-accepting netlayer
  in front of the room server, not a protocol translator.
- **Milestone 2. WebRTC DataChannel.** Two browsers speak OCapN directly over a
  reliable, ordered WebRTC DataChannel. The room introduces them and relays the
  WebRTC signaling (SDP/ICE) between them. The DataChannel is the message stream
  framing needs; DTLS is the encryption; the room's introduction supplies the
  signaling path. Composing that path with generic Host handoff redemption is a
  separate step.

## Scope (what this does not decide)

Milestone 1 has landed. `zig build wasm-driver` compiles the byte-fed Host
(`libpancake_driver`, ADR-0072) and the shared `libpancake_ocapn` vocabulary to
one freestanding `wasm32` module, `pancake_driver.wasm`;
`zig build wasm-driver-test` drives a keyed handshake between two Hosts over an
in-memory byte pipe; and `@pancake/web` (`bindings/ts/web`) runs the full
`@pancake/stack` surface over the module with a WebSocket byte channel,
proved end to end by `zig build web-peer-test`.

ADR-0089's DataChannel and signaling portions of Milestone 2 have also landed.
The browser and native arms establish direct channels after signaling, and a
shared native endpoint reports peer events through one readiness descriptor.
Standalone rendezvous, generic Host adoption, and handoff redemption remain in
[`docs/roadmap.md`](../../roadmap.md).

The Decision above predates the byte-fed Host consolidation (ADR-0072,
ADR-0079): the wasm target is now `libpancake_driver` rather than the
`pancake_ocapn.wasm` it names, and a browser drives the `Host` / `Session`
binding surface, not the retired `Peer` / `Node` shape. The seam it plugs into
is unchanged — one FFI boundary swapped for a WebAssembly instance.

## Alternatives Considered

- **Keep the bridge.** Rejected: the browser stays a client of a peer rather than
  a peer, so browser-to-browser introduction (the demo's whole point) can never
  be direct.
- **Reimplement the protocol in TypeScript.** Rejected: two codecs and two session
  engines drift, and it discards the one-core property that makes conformance a
  single authority. The core is already `wasm32`-clean; recompiling it is cheaper
  and truer than rewriting it.
- **WebTransport instead of WebRTC for Milestone 2.** Noted, not chosen: HTTP/3
  WebTransport gives QUIC-like streams but only browser-to-server, so it does not
  reach the browser-to-browser handoff. It is a reasonable alternative transport
  for the Milestone 1 (server-facing) role.

## Consequences

- A new binding target under `bindings/ts` (a `web`/wasm variant) that supplies a
  WebAssembly implementation of the FFI seam and reuses `mod.ts` above it.
- The C ABI (`src/c_abi/ocapn`) must stay compilable to a freestanding `wasm32`
  module with JS-callable exports and explicit linear-memory ownership: the same
  `ptr + len` and explicit-release contract it exports for C today, now honored
  across the WASM/JS boundary.
- A browser transport pair: a WebSocket netlayer the room server can accept on
  (Milestone 1), and a WebRTC DataChannel netlayer with room-relayed signaling
  (Milestone 2), added as `net.netlayer.Netlayer` residents the way iroh was
  (ADR-0055), with no core or session edit.
- At Milestone 1 the rooms `serve.ts` bridge retires. Milestone 2 supplies the
  direct keyed browser-to-browser session and signaling capability; composing
  those with generic Host handoff redemption remains separate work in ADR-0089.

## Forward compatibility

The C ABI's export surface stays free of host assumptions (no Deno, no OS types
in signatures) so a single archive serves both `Deno.dlopen` and WASM
instantiation. WebRTC's NAT traversal uses STUN, and TURN as a fallback relay;
TURN relays only encrypted DTLS bytes and sees no OCapN semantics, so the
capability model holds even when the direct path fails.

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

> **Shipped state.** The WebAssembly Host, WebSocket channel, browser and native
> WebRTC DataChannel arms, capability-carried signaling, generic Host adoption,
> and three-party redemption over WebRTC ship (ADR-0089, `webrtc-loop`,
> `webrtc-bridge-redeem`, `rooms-web-dm-webrtc`). ADR-0072 and ADR-0079 name the
> binding surface `Host` / `Session`, where this record says `Peer` / `Node`.

## Context

A browser cannot open a raw TCP socket or speak iroh's QUIC, so a browser tab
without a peer of its own is not an OCapN peer. A per-tab bridge (the rooms web
demo's server) has the browser talk JSON over a WebSocket to
a Deno process that holds the real glowcap connection through the C ABI and
relays between the two. The browser then holds no capability, runs no session,
and cannot be introduced to another browser directly. That is a gap in reach,
not in the protocol.

The core is sans-io. `src/ocapn/{model,codec,session,engine}` are
deterministic, no-I/O Zig that turn frames into events and messages into
frames, and `zig build cross-check` compiles that core for `wasm32`. The
[core-boundary First Principle](../../../AGENTS.md#first-principles) that keeps
sockets and schedulers out of the core is what lets the core run in a browser
sandbox unchanged.

## Decision

A browser binding is the sans-io core compiled to WebAssembly, exposed through
the same `Peer`/`Context`/`Node` API the other bindings present. The
TypeScript binding is layered for this: `bindings/ts/runtime/mod.ts` sits
on an FFI seam (`bindings/ts/runtime/internal/ffi/runtime.ts`, today `Deno.dlopen`
against `libglowcap_ocapn`). A browser binding replaces that one seam with a
WebAssembly instance: instantiate `glowcap_ocapn.wasm`, call its exports, and
marshal frames across the WASM/JS boundary as `ptr + len` as the C ABI does.
The public API shape is unchanged.

The browser also needs a transport, added in two milestones:

- **Milestone 1. WebSocket.** The browser holds a peer and moves OCapN frames
  over a WebSocket to a peer that accepts WebSocket connections. This makes the
  browser a first-class OCapN peer and retires the per-tab bridge: the rooms
  web server is a static file server plus a WebSocket-accepting netlayer in
  front of the room server, with no protocol translation.
- **Milestone 2. WebRTC DataChannel.** Two browsers speak OCapN directly over a
  reliable, ordered WebRTC DataChannel. The room introduces them and relays the
  WebRTC signaling (SDP/ICE) between them. The DataChannel is the message stream
  framing needs. DTLS is the encryption. The room's introduction supplies the
  signaling path. Composing that path with generic Host handoff redemption is a
  separate step.

## Scope (what this does not decide)

Milestone 1: `zig build wasm-driver` compiles the byte-fed
`c_abi_host` root and the shared `c_abi` vocabulary into one freestanding
`wasm32` module, `glowcap_driver.wasm`. The native `libglowcap_driver` loop
archive (ADR-0112) is a separate socket-owning artifact outside wasm.
`zig build wasm-driver-test` drives a keyed handshake between two Hosts over an
in-memory byte pipe, and `@glowcap/web` (`bindings/ts/web`) runs the full
`@glowcap/runtime` surface over the module with a WebSocket byte channel,
proved end to end by `zig build web-peer-test`.

Milestone 2: ADR-0089 ships the DataChannel and signaling portions. The browser
and native arms establish direct channels after signaling, and a shared native
endpoint reports peer events through one readiness descriptor. Generic Host
adoption and three-party redeem over WebRTC ship with that ADR (`webrtc-loop`,
`webrtc-bridge-redeem`, `webrtc-driver-provider`). A bare WebRTC locator needs
configured signaling authority, as documented in
[`docs/boundaries.md`](../../boundaries.md).

Following the byte-fed Host consolidation (ADR-0072, ADR-0079), the wasm root
forces the `glowcap_host_*` and `glowcap_*` families into one module instead of
exposing the `glowcap_ocapn.wasm` the Decision names, and a browser drives the
`Host` / `Session` binding surface. The seam is the same: one byte-fed FFI
boundary swapped for a WebAssembly instance.

## Alternatives Considered

- **Keep the bridge.** Rejected: the browser stays a client of a peer instead of a
  peer, so browser-to-browser introduction can never be direct.
- **Reimplement the protocol in TypeScript.** Rejected: two codecs and two session
  engines drift, and conformance loses its single authority. The core is
  `wasm32`-clean, so recompiling it is cheaper than rewriting it.
- **WebTransport instead of WebRTC for Milestone 2.** Not chosen: HTTP/3
  WebTransport gives QUIC-like streams but only browser-to-server, so it does not
  reach the browser-to-browser handoff. It is a reasonable alternative transport
  for the Milestone 1 (server-facing) role.

## Consequences

- A binding target under `bindings/ts` (a `web`/wasm variant) supplies a
  WebAssembly implementation of the FFI seam and reuses `mod.ts` above it.
- The C ABI (`src/c_abi/ocapn`) stays compilable to a freestanding `wasm32`
  module with JS-callable exports and explicit linear-memory ownership: the
  `ptr + len` and explicit-release contract it exports for C holds across the
  WASM/JS boundary.
- A browser transport pair: a WebSocket netlayer the room server can accept on
  (Milestone 1), and a WebRTC DataChannel netlayer with room-relayed signaling
  (Milestone 2), added as `net.netlayer.Netlayer` residents the way iroh was
  (ADR-0055), with no core or session edit.
- Milestone 1 retires the rooms per-tab bridge. Milestone 2 supplies the
  direct keyed browser-to-browser session, signaling capability, and generic
  Host handoff redemption (ADR-0089).

## Forward compatibility

The C ABI's export surface is free of host assumptions (no Deno, no OS types
in signatures) so a single archive serves both `Deno.dlopen` and WASM
instantiation. WebRTC's NAT traversal uses STUN, and TURN as a fallback relay.
TURN relays only encrypted DTLS bytes and sees no OCapN semantics, so the
capability model holds when the direct path fails.

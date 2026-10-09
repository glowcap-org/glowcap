---
id: ADR-0147
status: accepted
date: 2026-09-06
tags: [rooms, rust, wasm, application]
decision: "Rooms application policy and capability custody belong to one portable Rust implementation, compiled for process execution and linked with the Zig Host in browser Wasm; rendering and platform I/O remain adapters."
supersedes: []
superseded_by: []
amends: []
amended_by: [ADR-0148]
---

# ADR-0147 Rooms Rust application boundary

## Context

Rooms exercises glowcap's C ABI through a complete application. Application
behavior needs one owner across process services and browser execution, while
view interaction and platform I/O keep their own lifetimes.

## Decision

Portable Rust owns application policy, workspace intent, recovery, durable
effects and capability custody. The `rooms-application` crate is `no_std`
with allocation support. It declares method admission, transitions, replies and
notifications without acquiring filesystem or socket execution. Shared runtime
owners execute those declarations through supplied storage, time, entropy,
transport and task adapters.

CapTP remains in Zig and is governed by OCapN scenarios and Goblins fixtures.
The Rust binding consumes its C ABI. Browser linking puts Rust application code
and the Zig byte-fed Host in one Wasm memory. Process adapters use the binding's
driver tier. Context allocator callbacks keep heap ownership explicit.

React and TypeScript render observations and submit typed intent. Retained
capabilities belong to Rust application owners. View IDs and decoded snapshots
cannot grant authority. History and files cross bounded page/read interfaces.
The [session guide](../../rooms/session.md) maps managed Loam startup, receipts,
worker supervision and independent use/control handles.

## Runtime and platform boundaries

The room server, session peer, archive peer, web front and IRC edges are Rust
services. Their platform crate supplies listeners, TLS, storage and process
readiness. The browser supplies IndexedDB, Web Crypto, timers, WebSocket and
RTCDataChannel adapters. Both consume the same session executor and grants.

Direct linking preserves one memory; platform transports retain bounded queues
and physical close ownership. Host-owned tasks finish admitted transitions after
observer cancellation and retire on shutdown. Retirement waits before releasing
channels, callbacks or their parent RTC connection.

The byte relay does not parse CapTP. The deployment owns destination admission
and authenticates an iroh forwarding peer. Browser signaling retains the exact
registered directory name and source. IRC users have independent peers, while a
public inbox Host holds caller-scoped direct capabilities and drains them before
nickname release.

## Evidence and costs

`rooms-rust-test` exercises application and runtime contracts in a process.
`rooms-rust-browser-test` runs portable scenarios in Deno and Chromium.
`rooms-rust-browser-host-test` exercises the actual byte-fed Host and browser
transport adapters. Production page journeys prove application composition.
The [executor scenarios](../../../apps/rooms/rust/proofs/src/session_executor.rs)
physically reopen LMDB and IndexedDB while preserving exact foreign custody.

[Session measurements](../../../bench/rooms/session-costs.md) quantify selected
allocation and traversal costs. They establish neither maximum throughput nor
end-to-end application latency.

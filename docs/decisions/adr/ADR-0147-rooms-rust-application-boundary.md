---
id: ADR-0147
status: accepted
date: 2026-09-06
tags: [rooms, rust, wasm, application]
decision: "Rooms application policy and capability custody belong to one portable Rust implementation, compiled natively and linked with the Zig Host in browser Wasm; rendering and platform I/O remain adapters."
supersedes: []
superseded_by: []
amends: []
amended_by: [ADR-0148]
---

# ADR-0147 Rooms' Rust application boundary

## Context

Rooms' browser Share feature constructs the same session implementation as its
native session peer. The UI controller also mixes application operations with
presentation actions. A native-only translation would split existing shared
behavior; translating that entire controller would put viewer navigation and
composer interaction behind a systems boundary without an application reason.

The migration selected Rust for application behavior in both environments and
removed Deno from every Rooms server and session-peer process.
Deno may still build the TypeScript browser UI. The constraints are feature
preservation, one authority per fact, explicit effects and capability custody,
and measured allocation and copying cost. CapTP remains glowcap's Zig-owned
protocol, governed by its existing conformance evidence.

## Decision

Put Rooms policy, workspace intent, session recovery, durable effects, and live
application capabilities in portable Rust modules above glowcap. This includes
the Rooms protocol itself: method admission, authority transitions, replies,
notifications, and their consuming client behavior on both targets. Storage,
transports, time, entropy, and files are platform adapters. Application policy
decides when their results become visible. The initial application crate uses
`no_std` with allocation support, so it cannot acquire filesystem or socket
execution by importing the standard library.

Link the Zig byte-fed Host and OCapN archives with Rust into one browser Wasm
module. Calls between Rooms and CapTP stay inside one memory. Use
the existing C ABI context allocator callbacks to make heap ownership explicit;
the linking proof routes Host allocations to Rust and releases them before its
context ends. The native adapter can use the existing Rust binding's driver
tier, while browser adapters drive the byte-fed Host. CapTP state remains
in `src/driver/core/host/` and the OCapN layers in both cases.

Keep React rendering and presentation interaction in browser TypeScript.
Transfer typed commands and bounded view updates across the UI boundary.
Preserve drafts and shared selection as application intent. Retained
capabilities live in the application owner; view identifiers and deserialized
snapshots confer no authority. Large history and files use pages and chunks.

## Scope

The application continues to support multiple rooms, directories, memberships
and sessions. A room actor owns one room; a session owns its workspace across
rooms and directories. Each durable session has its own identity, state and
execution queue. Neither application scope nor process capacity is limited to
one room by this boundary.

The archive, session, room-server and standalone IRC service entrypoints run
Rust. Their native adapters compose portable application policy with the Rust
Host binding. The web launcher, HTTP front and deployment preparation run Rust.
The production browser links the Host with Rust and uses Rust owners for local,
hosted, and attached sessions, shared connections, workspace persistence and
archive custody. TypeScript renders typed observations and supplies platform
effects; its old Host, FFI and protocol clients are absent from the executable
page graph. Retained TypeScript protocol consumers and test fixtures are not
application owners. The living [shipped inventory](../../shipped.md) names
current feature coverage and evidence. This decision does not change wire formats, authorize a state reset,
replace React, or remove other applications' TypeScript bindings.

## Alternatives

| Shape | Assessment |
| --- | --- |
| Native Rust services with browser TypeScript policy | Creates two implementations of the session behavior already shared by Share and the native peer. |
| Rust application Wasm calling a separate Zig Wasm module through JavaScript | Feasible, but adds mediation and buffer copying between application and protocol. Direct linking has passed its initial execution proof. |
| Rust reimplementation of CapTP | Duplicates the conformance-owned Zig engine and expands the migration beyond Rooms. The Rooms protocol above it is being implemented in Rust. |
| Rust rendering as part of the application | Changes the UI framework without resolving the application ownership problem. Existing rendering can consume the new boundary. |

## Consequences and evidence

The shared grant ledger owns durable commit ordering. Storage acknowledgement
precedes in-memory policy changes. Cancellation or an indeterminate write
disables subsequent reads and commands until restoration, so an old projection
cannot be used as evidence that revocation failed. The storage adapter must
retire the underlying operation before restoration starts.

The IRC front gives each connected user an independent Rooms peer and directory
connection. One public Host serves all scoped direct-message inboxes, preserving
the configured public endpoint. Authenticated local Noise connections transfer
the inbox capabilities to the user peers; subsequent messages reach the inbox
Host directly. Both ends of each attachment serve inbound traffic immediately,
including gift redemption before that user first fetches an inbox alias. User
registration identifies the user's own Host; inbox handoff carries its separate
public reachability. Disconnect retires that user's publications and membership
before closing the IRC stream and releasing the nickname.

An offered inbox may arrive at a directory through an inline capability
handoff. The native directory settles it before announcing an introduction.
Portable policy captures the owner and recipient registrations and revalidates
their exact generations after the wait, so settlement cannot publish for a
replaced registration. The IRC front's native process scenarios exercise this
composition with multiple users, rooms, Noise/TCP/iroh inboxes, direct replies
and nickname reuse. This changes application custody and effect ordering without
adding a Rooms wire verb or changing CapTP's session identity rules.

`zig build rooms-rust-test` executes grant policy, failure, restart, HMAC, and
Host allocation/retirement contracts natively. It participates in
`zig build runtime-check`. `zig build rooms-rust-browser-test` runs the same Rust
scenario bodies in Deno and Chromium and checks that the linked module has one
memory and no imports. The latter proves direct linking for the functions it
calls, including the real Rust Context and locator binding with target-generated
layout assertions and archive fingerprints. The separate
`rooms-rust-browser-host-test` executes the real async Rust Host and Rooms
client in Deno and Chromium over an in-memory byte channel. A browser executor
polls Tokio's local tasks; browser timers and Web Crypto supply platform effects.
Native driver ownership is excluded from Wasm. Default browser Host contexts
use Rust's allocator, and all byte-fed close timestamps share one monotonic
epoch. The Rust channel boundary now preserves transport messages and exposes
physical retirement as a Host-owned effect. Session release and close observers
wait for it; observer cancellation cannot cancel that retirement. A controlled
WebRTC-profile channel tests framing, close refusal and rejected-admission
cleanup. Rust browser adapters now preserve WebSocket chunks and RTCDataChannel
messages, with bounded queues, incremental WebSocket writes, and callback
retirement. Chromium exercises the native web executable's directory through a
real WebSocket and a local RTC pair between Rust Hosts. Rust's `RtcPeer` now
owns peer construction and bounded SDP/ICE operations. Its Host-owned workers
finish admitted transitions after observer cancellation and retire on shutdown;
established data channels close before their parent connection. Chromium checks
these lifetimes with actual browser resources. The rooms-browser adapter now
connects both signaling halves to the existing Rust Rooms Exchange/Inbox.
The IndexedDB archive adapter is consumed by the production page. Chromium
proofs cover compatibility, workspace persistence, retention and startup
fallback.

The Rust browser Runtime now composes native web forwarding, locator-directed
relay profiles and directory-selected WebRTC around one Host. Complete locators
cross the web forwarding boundary; the native front owns target admission and
iroh authentication. Chromium exercises TCP and iroh forwarding plus reciprocal
keyed/Noise relay calls. Relay registration supervision and page composition
share the Rust attachment lifecycle.

Durable state execution and bounded command serialization now live in
`rooms-runtime`. Native `rooms-session` supplies filesystem documents, entropy
and its monotonic clock; browser Wasm uses the same execution owners with
browser platform adapters. Storage failures retain their concrete platform
type, while borrowed state views have platform-independent access errors.
Tab-hosted session documents remain volatile, preserving the existing Host
lifetime. Workspace preferences and archive records retain separate persistence
owners. Directory and room execution, operator and peering capabilities,
received offers, archive hosting and bounded snapshots also use shared runtime
owners. Session startup, retention barriers, worker supervision and root retirement
also share one lifecycle. Native listeners and readiness surround that owner.
The Wasm application owns browser execution, while React and its TypeScript
adapters project observations and admit reader intents at the UI boundary.
No throughput, application size, or latency improvement is claimed.

# Rooms in Rust

Status: historical. The migration is complete.

Rooms application policy and capability custody now have one portable Rust
implementation. Rust runs every Rooms server and session-peer process, and the
production browser links that same application with glowcap's Zig Host in one
Wasm module. React remains the presentation adapter. Deno remains a browser
build and test tool, never a Rooms server runtime.

This document records the completed boundary and its evidence. Current product
limits live in [boundaries](../boundaries.md), and shipped behavior lives in
[shipped](../shipped.md).

## Completed ownership

The native binaries are `rooms-server`, `rooms-session`, `rooms-archive`,
`rooms-web`, `rooms-irc-bridge`, and `rooms-irc-front`. Their Rust owners cover
room and directory policy, persistent authority, operations, peering, IRC,
history, visualization, HTTP serving, relay admission, readiness, and process
supervision.

The production page uses `rooms-browser` for local, hosted, and attached
sessions. Rust owns the Host, transport and signaling execution, shared
connections, directory supervision, reconnect, workspace intent, command and
result reconciliation, drafts, file capability execution, workspace writes,
and browser archive custody. TypeScript supplies reader gestures and browser
effects, then renders typed Rust observations. It does not reconstruct session
authority from those observations.

The retained TypeScript under `apps/rooms/lib/`, `apps/rooms/clients/`,
`apps/rooms/demos/`, and `apps/rooms/test/` is protocol-consumer and test
dogfood. It is not an application owner or a server launch path. The retired
TypeScript server and IRC owner paths are rejected by `zig build source-check`.

## Intent and reconciliation contract

A gesture and its outcome are different facts. Rust records the exact intent,
the authority generation it used, and the bounded operation identity before
starting fallible work. A completion may change state only when it still
matches that intent and generation. A corrected draft, replacement join,
renamed member, retired membership, changed archive, or newer navigation makes
the old completion stale. Stale completions may release their own resources and
report their own failures, but cannot clear newer input, revive retired
authority, or move the current view.

Commands separate issue acknowledgement from observed state. Applied effects
commit even when a later reply is lost. Effects proven unwritten may retry.
Ambiguous remote or storage outcomes remain pending until explicit recovery
resolves them. Pending outcome custody is bounded and is not evicted merely to
admit newer work.

Draft saves carry per-conversation tokens. Sending clears only the exact draft
submitted; delayed save and send outcomes cannot replace newer text. Directory,
room, direct-message, file, archive, bridge, and signaling operations apply the
same generation rule at their owning boundary.

## Failure contract

Expected failures cross the application boundary as typed failure codes with
specific recovery advice. This includes invalid input, absent or stale
authority, nickname and publication conflicts, pressure refusal, transport
loss, storage refusal, uncertain effects, and retired sessions.

Unexpected worker, adapter, cleanup, and post-commit failures reach a retained
owner and the generic failure surface. Spawned work is supervised or is listed
by the source gate with the bound that makes detachment safe. Shutdown stops
admission, retires underlying effects, joins workers, and preserves secondary
cleanup failures instead of replacing the primary cause.

## Persistence and capability custody

Application policy commits only after the required durable write succeeds.
Interrupted or ambiguous writes disable dependent progress until recovery.
Documents keep their existing versions and stable capability derivations;
corrupt or unknown documents are refused without reset. Bridge secrets remain
in their separate document and never enter exportable workspace state.

Capabilities live with the Rust application owner. Snapshots carry bounded
display identifiers, not authority. File content crosses adapters in bounded
chunks, archive transactions retain completion after observation is abandoned,
and transport callbacks retire before their parent Host completes shutdown.

## Evidence

The recurring gates cover the portable policy, native services, browser Wasm,
real browser integration, and product processes:

- `zig build rooms-rust-test`
- `zig build rooms-rust-browser-test`
- `zig build rooms-rust-browser-host-test`
- `zig build rooms-server-test`
- `zig build rooms-peers-test`
- the `rooms-web-*` browser scenario family in `tools/build/rooms.zig`
- `zig build ocapnviz-test` and `zig build ocapnviz-live-browser`
- the Goblins Rooms and IRC composition steps in `tools/build/relay_matrix.zig`

The process and browser scenarios exercise multiple rooms and directories,
reload and restart, reconnect, stale outcomes, grants and revocation, files,
archive retention and erasure, operations, IRC, peering, direct messages,
WebRTC, relays, TCP and iroh forwarding, visualization, pressure refusal, and
shutdown. `zig build check` owns the hermetic aggregate. Browser and external
interop steps remain explicit siblings because they need Chromium, Deno,
Racket, Goblins, or live host facilities.

No latency, throughput, or application-size improvement is claimed by the
migration. Bounded-resource evidence protects the new ownership shape;
performance claims require their own measurements.

## Historical constraints preserved

CapTP, reference routing, codecs, and protocol lifetime remain Zig-owned.
Storage, transports, browser APIs, clocks, entropy, and files remain platform
adapters. Rust application modules decide policy without importing browser or
native I/O. React retains rendering, focus, dialogs, viewer navigation,
clipboard and notification prompts. This is the boundary selected by
[ADR-0147](../decisions/adr/ADR-0147-rooms-rust-application-boundary.md), not a
rewrite of CapTP or the UI framework.

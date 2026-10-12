---
description: "Zig glowcap architecture guardrails: codec-neutral model, authoritative session, sync no-I/O core."
globs: src/**/*.zig, build.zig, include/**/*.h, tools/gen/header/**
paths:
  - "src/**/*.zig"
  - "build.zig"
  - "include/**/*.h"
  - "tools/gen/header/**"
---

# glowcap — Architecture Guardrails

## Authority

- The `1.0` profile answers to the pinned OCapN draft. Goblins compatibility is
  a separate feature and evidence question; a missing Goblins operation never
  redefines the version. `glowcap-next` tracks current OCapN direction,
  including meeting consensus and live proposals. Keep conflicting proposals as
  explicit variants; never blend them into an unsourced wire format.
- **Read `conformance/ocapn-spec/upstream/draft-specifications/` before
  changing anything glowcap puts on the wire**, and before deleting `next`
  behavior (update the submodules and check the minutes and owning issue
  first). A behavior the draft specifies is not a design question.
- Bindings are consumers, never semantic oracles.

```text
Frame -> Codec view -> Session state -> Outgoing Message -> Codec -> Frame
```

**Session state owns authority.** Codecs parse and render; they never decide
whether a reference, answer, export, import, or release is valid. If a change
moves authority into codec or adapter code, stop and redesign. A concern that
fits no layer goes to the layer that owns the decision, not the layer where the
symptom appeared. Export positions are minted only by `Peer.exportNextObject`;
the C Host exposes opaque identities, never positions.

When a request names a design pattern as an example, treat it as a candidate:
derive the improvement from the code and constraints, then choose the smallest structure
that earns its complexity.

## The core stays sync and no-I/O

- Protocol modules take no sockets, scheduler, background tasks, `std.Io`, or
  adapter policy. `arch-check` enforces the ban, including in `driver_core`.
- Adapters may use `std.Io`, transports, callbacks, and host scheduling, but
  never invent semantics, lifecycle, ownership, or policy. If a binding needs a
  second state machine, fix the core or C ABI. The C ABI and bindings marshal
  values, execute core-selected effects, and project outcomes into native
  idioms; protocol, business, retry, and recovery policy stay out of them.
- A nonblocking operation's cancel edge interrupts the effect and retires its
  worker before freeing state. Abandoning a result while I/O continues is not
  cancellation.

## Netlayers

CapTP never names a transport. A netlayer is a locator symbol (`tcp`,
`keyed-tcp`, `noise-tcp`, `keyed-relay`, `noise-relay`, `inproc`, `iroh`,
`webrtc`, `onion`), and socket code lives in transport residents. Only the code
that authenticated the end-to-end channel may report a proved peer; a hello's
session key proves continuity, never durable identity.

- Production: `noise-tcp` and `noise-relay` (Noise_XK proves the durable key,
  ADR-0107; `BlockingSession` refuses `noise-tcp`), `iroh` (QUIC node id),
  `webrtc` (signaling-authorized identity), and `onion`.
- `onion` is the one symbol the draft standardizes and Goblins ships. Wire
  onion locators stay bare (ADR-0108, ADR-0118).
- `tcp`, `keyed-tcp`, and `keyed-relay` are cleartext with no peer proof;
  `inproc` is tests only. Never make `tcp` a default, example, or demo; use
  `iroh`. Choose `tcp` only to reach a peer that speaks nothing else, and say it
  is cleartext.

`site/content/transports.smd` and `docs/boundaries.md` own the full matrix.

## Names carry three things

A key naming a table row carries its namespace, whose namespace it is, and when
it meant that. A bare `u64` or byte slice carries only the first, and each
costly bug here was a missing dimension. Fixes that held added a dimension
(disjoint ranges, identity stamps, domain separation, a token that dies with
its row); fixes that policed a peer-chosen name refused correct peers. Prefer a
key that carries its own dimensions. Close a position rule on both sides of the
wire, or write down why the other side needs none. A bare key must answer both
questions in `tools/check/source_check/namespaces.zig`.

## Layer Ownership

`build.zig`'s `layer_table` and `archive_table` are the authority for module
edges; `docs/architecture.md` is the tour; `source-check` holds this list
against `src/` both ways. Leaf `pub` is cross-file visibility, not a consumer
promise: only supported roots define the namespace, and tests import leaves
directly rather than widening a root.

- `foundation`: bytes, IDs, frame ownership, `Spill`, and the sealed channel.
- `ocapn/`: the protocol itself, reached as `glowcap.ocapn.<layer>`.
  - `ocapn/model`: codec-neutral semantic types.
  - `ocapn/codec`: encode, decode, and borrowed views.
  - `ocapn/session`: validation and the authoritative tables.
  - `ocapn/engine`: the caller-owned `Peer`, `step`, dispatch, and drain.
- `actors`: the sync `Vat` above the engine, plus local-only time travel.
- `loam`: application persistence, collections, records, hosting, and the
  managed access extension; `docs/loam.md` owns its durable profile.
- `diagnostics`: the typed record and bounded journal for failures with no
  surviving caller (ADR-0115). It owns no global storage or policy.
- `net`: the one place `std.Io` enters; stream folding and residents.
- `driver/core` (`driver_core`): the sans-io serve core and byte-fed `Host`.
  `host.zig`'s alias table indexes the verbs split across `host/` siblings.
- `driver`: the native surface above the core (`BlockingSession`,
  `HostRuntime` with its `Session`/`Server` views, `Bridge`), entropy, and
  transport constructors. It adds no CapTP semantics.
- `c_abi/`: composable archives that share types by layout, not symbols
  (ADR-0055, ADR-0059). Signatures reflect from Zig; header prose lives in
  `tools/gen/header/*.zig`.
  - `c_abi/shared`: archive-neutral layouts; declares no `export fn`.
  - `c_abi/ocapn`: `libglowcap_ocapn`. Each handle frees through one
    `glowcap_*_release`; `*_close` never frees. A C-convention function
    releases by hand on refusal, since `errdefer` never runs there.
  - `c_abi/host`: `libglowcap_host`, the byte-fed Host tier (ADR-0072).
  - `c_abi/loam`: optional portable Store, content callbacks and submitted
    storage effects borrowing the existing Host (ADR-0185).
  - `c_abi/loam_lmdb`: optional LMDB executor and exclusive Store owner;
    creates no Host or actor runtime (ADR-0185).
  - `c_abi/driver`: `libglowcap_driver`, the native loop adopting a Host
    (ADR-0112). It names no concrete transport; `provider_registry.Registry`
    alone adapts provider tables.
  - `c_abi/wasm`: the browser binding's freestanding entry root (ADR-0070).
  - `c_abi/net_transport`: grouping for transport archives, each exporting only
    its own `glowcap_<transport>_*` family. Children are `tcp`, `inproc`,
    `iroh`, `onion`, `relay`, and `webrtc`; WebRTC exposes no fake address
    `Netlayer`.
- `oracle`: canonical scenario drivers for tests; not on the runtime path.

## CapTP vocabulary (ADR-0079)

| Name | Is |
| --- | --- |
| `Host` / `GlowcapHost` / binding `Host` | multi-session CapTP product; owns `engine.Node` |
| `engine.Node` | sans-io handoff router |
| binding `Session` / `driver.Session` | one-partner view onto a Host session (ADR-0090) |
| `driver.BlockingSession` | no-router single-connection tier; the only tier for a transport with no pollable descriptor |
| Goblins `mycapn` | product maps to Host; router tables map to `engine.Node` |

There is no binding `Node` or `Connection`, no `driver.Connection`, and no
multi-session "node" alias; `net.Connection` is the byte stream only.

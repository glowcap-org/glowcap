# pancake

<img src="assets/pancake.png" alt="" align="right" width="140" />

[![Zig](https://img.shields.io/badge/language-Zig-f7a41d.svg)](https://ziglang.org/)
[![zero-copy contract](https://img.shields.io/badge/zero--copy-contract-blue.svg)](docs/architecture.md)

> **pancake is a codec-neutral [CapTP](http://erights.org/elib/distrib/captp/) core for [OCapN](https://github.com/ocapn/ocapn).**
> **Syrup where OCapN requires it. Owned frames or borrowed views wherever frames cross a boundary.**
> **Because you can't have pancakes without syrup.**

## What Is This?

pancake is a Zig implementation of the object-capability networking core: two
programs hand each other unforgeable references to remote objects and call
methods across a session with the same authority discipline as local
references. No ambient authority, no string-typed permissions. If you hold the
reference, you can use it.

It targets OCapN, the open object-capability network protocol from
[Spritely Institute](https://spritely.institute/) and the OCapN community. The
core is library-shaped, explicitly memory-managed, and designed so protocol code
keeps ownership, allocation, wire format, cryptography, I/O, and host scheduling
boundaries visible.

The conformance authority is OCapN behavior — as defined by Spritely Goblins on
the wire and the OCapN test suite. The in-repo gate checks pancake's protocol
scenarios and pancake-authored Syrup byte vectors against that intent; live
external-peer interop is the next step, not yet wired. The package name is
`pancake`.

## On The Wire Today

Implemented Zig behavior includes:

- **Frames.** `Frame` has one visible owner, `FrameView` borrows bytes, and
  `FrameShape` carries explicit byte vs word-aligned frame metadata.
- **Model.** Codec-neutral CapTP model types exist independently of the wire
  encoding that carried them.
- **Syrup.** The Syrup codec encodes the current message model against
  pancake-authored Syrup byte vectors (cross-checked through the upstream Syrup
  encoders, not Goblins captures), decodes borrowed views for the supported
  operation set, and materializes owned messages for runtime-surfaced operations
  including start-session and handoff.
- **Session/runtime.** Sessions own profile/features, lifecycle,
  import/export/answer/release authority, validate-then-apply, and feature
  gates. `Peer` remains caller-owned and drives outbound profile-aware encoding,
  V1.0 resolve-me-desc synthesis, borrowed inbound dispatch, owned queued
  inbound frames, outbound drains, and application-visible events for the
  supported decoded operations.
- **Third-party handoff.** Give and receive work end to end. The Syrup codec
  round-trips the handoff fixtures, the session owns a gift table with
  deposit/withdraw bookkeeping, signed-give consistency, and handoff-count replay
  rejection, and `runtime.cross_peer` routes the gifter → exporter → recipient
  flow across peers with signature verification injected at the boundary.
- **Promise pipelining.** Sessions own the inbound-answer table, listeners, and
  stored resolutions; `runtime.pipeline` carries the pure transforms. A pipelined
  `op:deliver` against an unresolved answer queues and drains to the resolution
  (local delivery, requeue, or far-forward) when `op:resolve` settles, and a
  multi-hop call path decomposes at the sender into chained single-hop frames so
  every `desc:answer` on the Syrup wire stays flat.
- **Relayed-resolution forwarding.** An `op:listen` on a handoff-imported promise
  installs against the third-party-hosted import; when the introducing session
  forwards the host's resolution, `runtime.cross_peer.drainRelayedResolutions`
  fires the listeners and stores the resolution so a late listener fires
  immediately (ADR-0009).
- **Bootstrap fetch (initiator).** `runtime.fetch` builds the canonical
  bootstrap-fetch `op:deliver` and matches the partner's settlement — an
  `op:resolve` or a resolver-callback `op:deliver` — into an owned outcome.
  Driving the wire loop between the two is an adapter concern; the core ships the
  no-I/O halves.
- **Bootstrap fetch (responder).** `Peer.registerBootstrapCap(swissnum)` exposes
  a local capability behind a swiss-number; an inbound `'fetch` to the bootstrap
  export is then recognized and answered automatically by the dispatcher
  (`runtime.bootstrap` synthesizes the `Resolve`; the V1.0 path renders it as a
  resolver-callback), with `break "unknown swissnum"` for an unregistered
  swissnum (ADR-0006 responder half).
- **Sturdyref enliven (initiator).** `runtime.sturdyref` turns a persistent
  `(peer, swissnum)` sturdyref into a live `Reference` over the existing
  bootstrap-fetch: a feature-negotiated + open precondition gate, a session dedup
  cache (swissnum → `(import_id, kind)`, kind preserved) that short-circuits a
  repeat enliven with no wire traffic, and an in-flight marker that collapses a
  concurrent enliven onto the outstanding answer. The wire loop is adapter-driven,
  exactly like `runtime.fetch`.
- **Distributed equality.** `model.referencesEqual` is the codec-neutral
  structural-equality predicate — the in-memory evidence for OCapN Pass Invariant
  Equality (ADR-0013): two references that name the same target compare equal
  regardless of which codec or profile carried them. `runtime.SessionRegistry`
  enforces one session per `PeerId` (`PeerAlreadyOpen` on a duplicate open), so
  cross-session equality reduces to same-session equality on `(import_id, kind)`;
  the sturdyref dedup cache supplies the sturdyref-vs-handoff collapse.
- **Handshake feature negotiation.** `model.FeatureSet.intersect` is the
  per-feature AND, and `runtime.negotiation.negotiate` is the pure, symmetric
  pick of the most-preferred shared codec plus the intersected feature set over
  two `Offer`s. `op:start-session` carries no feature operand (pancake does not
  extend OCapN's wire shapes), so both ends compute the same answer from the same
  offers; `factories.pairedWithOffers` constructs both peers with the negotiated
  set, so neither exercises a capability the other withheld.
- **Fail-loud aborts.** A rejected inbound frame — a codec-malformed frame or a
  session state-machine refusal — projects through `runtime.abort_projection` to
  a typed outbound `op:abort` (and a session close where warranted) before the
  error surfaces, instead of bubbling a bare host error and leaving the partner
  hanging. Both inbound entry points share the projection.
- **Resource caps.** `SessionLimits` bounds the partner-driven tables — imports,
  the seen-handoff-count replay set, and deposited gifts — alongside the existing
  pipelining caps; each overflow is a loud `*CapExceeded` error that projects to
  a `ResourceExhausted` abort (ADR-0025), never a silent drop.
- **C ABI and adapters.** The C ABI frame vocabulary is fixed-width and
  release-explicit. Borrowed frames dispatch synchronously; managed frames
  transfer ownership without copying; events return the originating frame in the
  negotiated codec with explicit release and no re-encode. `std.Io` appears at
  the adapter boundary, not in the core.
- **Protocol oracle bridge.** `zig build oracle-check` enumerates shipped
  message arms, checks pancake-authored Syrup fixture parity (cross-encoder), and runs runtime scenarios
  including the multi-peer third-party handoff. `conformance` also drives a
  deliver → resolve round-trip, a handshake → bootstrap-fetch auto-serve scenario
  (the ADR-0006 responder half), and a cross-mode parity check that proves the
  borrowed (`recvBorrowed`) and owned (`feedInbound` + `step`) inbound entry
  points run one dispatcher (byte-identical observable output).
- **Architecture gate.** `zig build arch-check` walks `src/**/*.zig`, parses the
  `@import` edges, and enforces the layer dependency DAG (codec-neutral session,
  no-`std.Io`-in-core, codecs own no authority) — a new top-level module with no
  declared rule fails the gate loudly.
- **Rust C ABI dogfood.** A Rust crate links `libpancake` through the C ABI and
  drives a peer smoke test through the public host boundary.

## Not Implemented

A byte-stream netlayer ships (`net_adapter`): the active codec's own decoder
finds frame boundaries (one parser, ADR-0029), a `Connection` folds it over
`std.Io.Reader`/`Writer`, and `net_adapter.tcp` (`tcp-testing-only`, cleartext)
proves a handshake-to-open + bootstrap-fetch round-trip over a real socket. The
C ABI re-exposes it as blocking endpoint handles with a `last_error` seam
(ADR-0030). Still outside the shipped surface: production transports (TLS,
QUIC/iroh), full-duplex backpressure, crossed-hellos, and the small-buffer /
bounded-overflow read path — all deferred by name in ADR-0030.

Sturdyref enliven ships its initiator half (`runtime.sturdyref`); its
responder half is the same inbound-`'fetch` serving path
(`Peer.registerBootstrapCap`), since an enliven is a `'fetch` against the local
bootstrap exporter. Distributed equality ships the in-memory substrate
(`model.referencesEqual`, `runtime.SessionRegistry`); container-type Pass
Invariant Equality (value-tree equality on List / Struct / Tagged shapes) is not
implemented.

The Cap'n Proto codec ([`src/codec/capnp/`](src/codec/capnp/), [ADR-0026](docs/decisions/adr/ADR-0026-hand-rolled-capnp-codec.md))
is runtime-integrated and selectable on a live session: a peer pair negotiates it
(`runtime.factories.pairedWithCodec`), and the handshake plus all subsequent
traffic ride that codec through the codec-dispatch seam (`session.codec`). The
session state machine is codec-neutral, so the Goblins-v1.0 resolver-callback
translation is codec-blind. Cross-codec semantic parity (Invariant 8's two-codec
requirement) is proven: the deliver/resolve and bootstrap-fetch conformance
scenarios produce identical *observable* traces on Syrup and Cap'n Proto: the
state machine is codec-neutral, so the behavior does not depend on which codec
carried it (the two wire encodings differ; the observable trace does not). The one Cap'n
Proto boundary that remains is the real-crypto handshake — the canonical
`<my-location …>` signing input is profile-defined (Syrup), so a Cap'n Proto
session uses the stub-key path.

## Design Posture

- Library first, not framework first.
- Protocol semantics are fixed, correct, and interoperable.
- Implementation overhead is aggressively minimized.
- The canonical core stays deterministic, sync, and no-I/O.
- Zig `std.Io` belongs in adapter/netlayer layers, not in the core or C ABI.
- C ABI surfaces stay C-shaped: opaque handles, fixed-width return codes,
  `ptr + len` frames, callbacks, and explicit release functions.
- Zero-copy is a contract: every copy is forbidden, intentional, or measured.
- Frame movement defaults to owned transfer or bounded borrow; copy helpers live
  in `test/support`, not in production modules.
- Public examples compile as part of the build; README usage must stay honest.

## Foundation Contract

Ownership APIs and inbound dispatch surfaces every protocol layer builds on:

- `Frame.initOwned` / `Frame.initExternal`: adopt storage without copying;
  alignment and release hooks stay explicit at the API boundary.
- `feedInbound(Frame)` and `recvBorrowed(FrameView)`: owned queued vs bounded
  borrowed inbound dispatch.
- Tests and benchmarks prove views do not allocate or copy and track frame/view
  overhead.

## Devcontainer

Open with _Dev Containers: Reopen in Container_, then:

```sh
bash .devcontainer/post-create.sh
zig build check
```

Toolchain pins: [`./.devcontainer/pins.sh`](.devcontainer/pins.sh). Boundaries and
environment notes: [`./.devcontainer/README.md`](.devcontainer/README.md).

## Quick Start

```sh
zig build
zig build check
zig build oracle-check
zig build rust-dogfood
zig build bindings
zig build examples
zig build test
zig build bench-frame-view
```

`zig build` installs `libpancake.a`, `libpancake.so`, and `pancake.h` under
`zig-out/`.

`zig build check` runs the architecture gate, tests, the example programs, Rust
C ABI dogfood, the protocol/Syrup oracle checks, and the frame/view benchmark
smoke check. `zig build arch-check` runs the layering gate on its own.
`zig build oracle-check` runs the protocol manifest and pancake-authored Syrup
fixture checks directly.

## Examples

Runnable CapTP walkthroughs, narrated in each program's `//!` header and run
under `zig build examples` (and `zig build check`) — see
[`examples/README.md`](examples/README.md) for the index.

- [`examples/zig/01_call_a_remote_method.zig`](examples/zig/01_call_a_remote_method.zig)
  pairs two peers; one calls a method on the other and reads the answer back.
- [`examples/zig/02_look_up_by_name.zig`](examples/zig/02_look_up_by_name.zig)
  fetches a capability through the bootstrap object by swiss-number — the server
  side is just `registerBootstrapCap`, and the runtime answers the `'fetch`.

Lower-level library mechanics:

- [`examples/zig/frame_view.zig`](examples/zig/frame_view.zig) consumes pancake
  as a Zig library and demonstrates owned `Frame` to borrowed `FrameView`.
- [`examples/c/frame_view.c`](examples/c/frame_view.c) consumes
  [`pancake.h`](include/pancake.h), links `libpancake`, and calls an exported C
  ABI symbol.

## Reference & Conformance

- [`conformance/`](conformance/) — external conformance pressure: the OCapN
  test suite (submodule), pancake's Spritely Goblins peer, the accountability
  application + its `.data/` corpus, and the KERI/episode oracles. Initialize
  the upstream submodules with `bash conformance/bootstrap-submodules.sh`.
- [`bindings/`](bindings/) — per-language consumers of the `libpancake` C ABI
  (rust, deno, python, racket), each dogfooding the ABI. Run with
  `zig build bindings`.
- [`test/oracles/`](test/oracles/) — the canonical Syrup byte corpus (gated by
  `zig build oracle-check`) plus the Goblins (Racket) and pancake (Python)
  generators that reproduce it.

## Documentation

- [`docs/architecture.md`](docs/architecture.md) explains the memory, C ABI, and
  layer boundaries.
- [`docs/planning/reference-rehoming.md`](docs/planning/reference-rehoming.md)
  is the plan of record for the re-homed reference material above.
- [`AGENTS.md`](AGENTS.md) is the agent entrypoint for invariants and
  scaffolding discipline.


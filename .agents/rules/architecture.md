---
description: "Zig pancake architecture guardrails: codec-neutral model, authoritative session, sync no-I/O core."
globs: src/**/*.zig, test/**/*.zig, bench/**/*.zig, examples/**/*.zig, examples/**/*.c, include/**/*.h, build.zig, README.md, docs/**/*.md, AGENTS.md
---

# pancake — Architecture Guardrails

## Authority runs one direction

Default `1.0` answers to actual Goblins behavior. `pancake-next` tracks current
OCapN direction, including recorded consensus and live proposals, not only text
already merged into the draft. Before deleting next behavior as non-spec,
update the conformance submodules and inspect the meeting record plus the open
issue or PR that owns it. Preserve conflicting proposals as explicit variants
until consensus selects one; do not blend them into an unsourced wire format.
Bindings remain dogfoods, never semantic oracles.

```text
Frame -> Codec view -> Session state -> Outgoing Message -> Codec -> Frame
```

**Session state owns authority.** Codecs parse and render bytes; they do not
decide whether a reference, answer, export, import, or release is valid.
**If a change moves authority downward into codec or adapter code, stop and
redesign.** When a concern fits no layer above, give it to the layer that owns
the decision, never the layer where the symptom appeared.

Export positions are minted only by the session's allocator
(`Peer.exportNextObject`), and the C Host exposes opaque Host identities rather
than export positions. A counter kept outside the session eventually collides
with that same counter's resolver and bootstrap exports and silently aliases a
live object.

## The core stays sync and no-I/O

The portable core takes no sockets, no hidden scheduler, no background tasks, no
`std.Io` in protocol modules, and no adapter policy inside codecs, session, or
engine. Adapters may use `std.Io`, transports, callbacks, and host scheduling,
but **they never add CapTP semantics the core lacks.**

CapTP is transport-agnostic and never names a transport. A netlayer is a locator
transport symbol (`tcp`, `keyed-tcp`, `keyed-relay`, `inproc`, `iroh`,
`webrtc`), and socket and stream code lives in transport residents.
`keyed-tcp` is its own symbol reusing `tcp` sockets, not a second CapTP stack.

## Not every shipped netlayer is deployable

The split is not obvious from the code. The human page is
`site/content/transports.smd` and the consequences are in `docs/boundaries.md`.

| Symbol | Peer proof | Channel | Verdict |
| --- | --- | --- | --- |
| `tcp` | none; the designator is an address | cleartext | testing and Goblins interop only |
| `inproc` | none, and nothing to prove | in-process pipes | tests only |
| `keyed-tcp` | none; key designator is a dial target only | cleartext | trusted network only |
| `keyed-relay` | none; key designator is a dial target only | cleartext `ws://` | trusted relay and network only |
| `webrtc` | identity authorized by signaling | DTLS DataChannel | production |
| `iroh` | QUIC remote node id, the one realizer proof in the tree | encrypted QUIC | production |

**`tcp` is not an ordinary default.** The OCapN draft requires a netlayer to
keep a session insertable only by its participants, upstream Goblins ships no
TCP netlayer, and the upstream suite's own is `tcp-testing-only`. Reach for
`iroh` when adding a default, an example, or a demo; pick `tcp` only to reach a
peer that speaks nothing else, and say in the same breath that it is cleartext.

A fresh session key signs each hello, so it proves session continuity and never
durable identity. Only the code that authenticated the end-to-end channel may
report a proved peer.

## Names carry three things

A name that indexes a table is three things: the namespace it belongs to, whose
namespace that is, and when it meant what it meant. A Zig type carries the
first. A key of `u64` or `[]const u8` carries only the first, and the other two
live in whatever the author was thinking.

That gap is the costliest bug class this core has had, and every instance was
one missing dimension: a near _or a far_ from one session naming an object on
another, a projection settling an answer position the partner had released and
reasked, two gifters reusing one gift id. **Both directions of that first one
are live**, so when you close a position rule on one side of the wire, write
down why the other side does not need the same rule, or give it the same rule.

Every fix that held added a dimension: disjoint ranges, identity stamps, domain
separation, a token that dies with its row. **Every fix that had to be taken
back tried to _police_ the collision instead**, and policing a name the protocol
lets a peer choose refuses correct peers.

So prefer a key that carries its own dimensions, a distinct type or a composite
naming the owner. Where a key stays bare, `zig build meta-check` requires it to
answer both questions in `tools/check/meta_check/namespaces.zig`, in both
directions.

## Layer Ownership

Where code goes. `build.zig`'s `layer_table` and `archive_table` are the
authority for module edges and the archive set, `docs/architecture.md` is the
readable tour, and `meta-check` holds this list against `src/` in both
directions.

- `foundation`: bytes, IDs, frame ownership, and the `Spill` where a stream's
  not-yet-consumed bytes wait. The `Spill` lives this low because both
  stream-reading tiers need one and neither imports the other.
- `ocapn/`: the OCapN / CapTP protocol itself, the four layers that _are_ the
  protocol. Everything else adds none. Reached as `pancake.ocapn.<layer>`.
  - `ocapn/model`: codec-neutral semantic types.
  - `ocapn/codec`: encode and decode, plus borrowed semantic views.
  - `ocapn/session`: validation and the authoritative tables.
  - `ocapn/engine`: the caller-owned `Peer`, `step`, inbound dispatch, outbound
    drain.
- `actors`: Goblins-shaped local objects and a sync, no-I/O `Vat` (spawn,
  near-call `$`, eventual-send `<-`, promises) above the engine, adding no CapTP
  semantics the engine lacks. Also owns opt-in local time-travel (ADR-0060),
  which is local-only and never wire state.
- `persistent`: a sharp leaf of persistent immutable collections, one
  refcounted-HAMT `PersistentMap` (ADR-0061) so a persistent actor's functional
  `become` is O(log n). Pure, no-I/O, imports nothing, off the public `pancake`
  namespace, reached only by opt-in persistent actors.
- `net`: the one place `std.Io` enters. Folds the one parser over a stream and
  realizes netlayer residents over byte streams. Not part of the no-I/O core.
- `driver/core` (`driver_core`): the sans-io serve core the driver stands on.
  The vat serve loop `Served` and its verbs, the shared vocabulary, turn-time
  `spawnAt`, stateless GC, and the byte-fed multi-session CapTP host core
  `Host`. It is `core = true`, so **`arch-check` bans I/O here exactly as in
  `engine`, and that ban is what keeps a socket from creeping back into the
  serve core** (ADR-0072). A byte-fed consumer (the `libpancake_host` C ABI, a
  browser) drives a `Served` or a `Host` directly, net-free. The `Host` is split
  across sibling files by responsibility, each presenting its verbs as `Host`'s
  own through decl aliases; `host.zig` keeps the state, the byte pump, the serve
  hooks, and the application verbs, and **its alias table is the index**.
  `host_pump.zig` is private to the directory (`meta-check` holds this), and a
  helper made `pub` for a sibling says so where it is declared.
- `driver`: the native application surface above `driver_core`, `actors`, and
  `net`, composing the sans-io core with I/O. `BlockingSession` is the
  no-router single-connection tier; `driver.Session` and `driver.Server` are
  views onto an owning `driver.PollHost` (ADR-0090), so the front door redeems
  handoffs; `driver.Bridge` plus `completion.Loop` is the scale embedding of the
  same core (ADR-0068, ADR-0072, ADR-0076). Language bindings drive
  `driver_core.Host` through `libpancake_host` rather than rebuilding a Zig Host
  type. Adds no CapTP semantics. It also owns the `drawSessionSecret` entropy
  boundary and the transport constructors, the members that must stay above the
  core's I/O ban.
- `c_abi/`: the public C ABI family, grouped the way `src/ocapn/` groups the
  protocol core. It ships as composable archives that **share types by _layout_,
  not symbols** (ADR-0055, ADR-0059), each exporting only its own
  `pancake_<family>_*` family. Signatures and constants are reflected from Zig
  while header prose lives in `tools/gen/header/*.zig`, so a C-contract change
  edits both and then runs the `gen-*` step.
  - `c_abi/shared` (`c_abi_shared`): the shared C-ABI vocabulary leaf: C-visible
    frame and context types, return and codec codes, allocation policy, managed
    frames, and the per-thread last-error slot. **Declares no `export fn`**, so
    every archive reuses it without inheriting another's exports.
  - `c_abi/ocapn` (`c_abi`): `libpancake_ocapn`, C-shaped only. Every handle
    frees through exactly one `pancake_*_release`; a `*_close` is a shutdown
    lever and never frees, which `meta-check` holds in the generated headers.
  - `c_abi/host` (`c_abi_host`): `libpancake_host`, the byte-fed host tier
    (ADR-0072). An embedder owning its own loop, sockets, and entropy drives a
    full multi-session CapTP Host with bytes, and the host's own effects surface
    as actions, so publish, fetch, send, vows, projections, and the full
    three-party handoff run from C with no socket.
  - `c_abi/wasm` (`c_abi_wasm`): the browser binding's freestanding `wasm32`
    entry root (ADR-0070). Forces the `pancake_*` and `pancake_host_*` families
    into one loadable module and adds the two JS-to-wasm linear-memory
    primitives. Adds no CapTP surface; sits outside the layer DAG.
  - `c_abi/net_transport`: the grouping directory for the transport archives,
    holding no source of its own. Each child is its own `.graph = false` layer,
    outside the layer DAG because it links a sidecar or an injected resident,
    neither expressible as a DAG edge.
    - `c_abi/net_transport/tcp` (`c_abi_net_transport_tcp`): the TCP archive,
      exporting only `pancake_tcp_*`.
    - `c_abi/net_transport/inproc` (`c_abi_net_transport_inproc`): the
      in-process archive, exporting only `pancake_inproc_*`.
    - `c_abi/net_transport/iroh` (`c_abi_net_transport_iroh`): the iroh archive,
      exporting only `pancake_iroh_*`. `arch-check` still claims the directory
      for file coverage and the I/O bans.
    - `c_abi/net_transport/webrtc` (`c_abi_net_transport_webrtc`): the WebRTC
      archive (ADR-0089), exporting only `pancake_webrtc_*`. Alone among the
      transports it imports `c_abi_shared` and not `net`, because its surface is
      an endpoint readiness fd plus peer creation, signaling, non-blocking
      try-I/O, and close. **A bare locator carries no signaling authority, so
      the resident exposes no fake address `Netlayer`.**
- `oracle`: canonical CapTP scenario drivers, the observable-trace reference the
  Zig oracle tests compare against. Its own module off the public `pancake`
  namespace, imported by tests and consumed by no binding, because the bindings
  prove the C ABI by dogfood rather than oracle traces. Not on the runtime path.
  (The top-level `conformance/` tree is unrelated: it holds external authority.)

## CapTP vocabulary (ADR-0079)

Kept here, not in human first-read docs.

| Name | Is |
| --- | --- |
| `Host` / `PancakeHost` / binding `Host` | multi-session CapTP product; owns `engine.Node` |
| `engine.Node` | sans-io handoff router |
| binding `Session` | one-partner app object, a view onto a `driver_core.HostSession` under a Host |
| `driver.Session` | the same contract natively, a view onto an owning `driver.PollHost` (ADR-0090) |
| `driver.BlockingSession` | the no-router single-connection tier, the one place `Settled.give` surfaces, and the only tier a transport with no pollable descriptor can ride — so it does not collapse into `PollHost` |
| Goblins `mycapn` | endpoint, roughly Host plus router tables, roughly `engine.Node` |

Binding `Node` and `Connection` are deleted, and `net.Connection` is the byte
stream only. There is no multi-session "node" alias for `PancakeHost` and no
`driver.Connection`.
